#!/bin/bash
# ============================================================================
#  ag_patcher.sh — байтовый + JS-патч Antigravity (macOS / Linux)
#  Метод взят у confeden/Antigravity (https://github.com/confeden/Antigravity)
#
#  Зависимости: bash и perl. Больше ничего не ставит и не качает.
#  perl есть штатно и в macOS, и в Ubuntu (perl-base — Essential).
#
#  1) Нативные бинари (language_server*, agy):
#     "ineligible" → "inexigible" (обе по 10 байт, размер не меняется).
#     Так Language Server перестаёт видеть отказ eligibility в protobuf.
#
#  2) Standalone IDE (форк VS Code):
#     out/main.js — перепись confirmUserForService (порт patch_ide.rs).
#     Именно этот JS рисует «Sorry, this account is ineligible».
#     extensions/.../extension.js — порт patch_extension_js.
#     Откат из соседнего .ag_backup: тело функции переписано, не переименовано.
#
#  Сеть не трогается: ни DNS, ни /etc/hosts, ни прокси.
#  https_proxy → AG_LS_PROXY не делается: локального прокси здесь нет.
#
#  macOS: после правки Mach-O — ad-hoc codesign, иначе ядро убивает бинарь.
#  Linux: подписи нет, достаточно записи в файл.
#
#  Запуск:
#      bash ag_patcher.sh              меню
#      bash ag_patcher.sh patch
#      bash ag_patcher.sh unpatch
#      bash ag_patcher.sh status
# ============================================================================

export AG_FROM="ineligible"
export AG_TO="inexigible"

OS=$(uname -s)
IS_DARWIN=0; [ "$OS" = "Darwin" ] && IS_DARWIN=1

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_DIM='\033[2m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }
dim()  { say "${C_DIM}$1${C_N}"; }

# Под sudo $HOME указывает на root. ~user работает и в bash macOS, и в Linux.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  USER_HOME=$(eval echo "~$SUDO_USER")
  case "$USER_HOME" in "~"*|"") USER_HOME="/home/$SUDO_USER"; [ "$IS_DARWIN" -eq 1 ] && USER_HOME="/Users/$SUDO_USER" ;; esac
else
  USER_HOME="$HOME"
fi

tilde() { case "$1" in "$USER_HOME"/*) echo "~${1#$USER_HOME}";; *) echo "$1";; esac; }

file_owner() {
  if [ "$IS_DARWIN" -eq 1 ]; then stat -f '%u' "$1" 2>/dev/null
  else stat -c '%u' "$1" 2>/dev/null
  fi
}

# ------------------------------------------------------------------ perl: бинарь
# Замена через index/substr, без регулярок. Запись — tmp рядом + rename
# (атомарно на одном томе). Режим и владелец копируются с оригинала.
PERL_BIN=$(cat <<'ENDPERL'
use strict; use warnings;
my ($mode, $path) = @ARGV;
open(my $fh, "<", $path) or die "open: $!\n";
binmode($fh);
my $data = do { local $/; <$fh> };
close($fh);
if ($mode eq "native") {
    my $m = substr($data, 0, 4);
    print((
        $m eq "\x7fELF"
        || $m eq "\xFE\xED\xFA\xCE" || $m eq "\xFE\xED\xFA\xCF"
        || $m eq "\xCE\xFA\xED\xFE" || $m eq "\xCF\xFA\xED\xFE"
        || $m eq "\xCA\xFE\xBA\xBE"
    ) ? "1\n" : "0\n");
    exit 0;
}
my ($from, $to) = ($ENV{AG_FROM}, $ENV{AG_TO});
die "signature length mismatch\n" if length($from) != length($to);
sub count_of {
    my ($hay, $needle) = @_;
    my ($n, $pos) = (0, 0);
    while ((my $i = index($hay, $needle, $pos)) >= 0) { $n++; $pos = $i + length($needle); }
    return $n;
}
if ($mode eq "count") {
    printf("%d %d\n", count_of($data, $from), count_of($data, $to));
    exit 0;
}
my ($src, $dst) = $mode eq "patch" ? ($from, $to) : ($to, $from);
my ($n, $pos) = (0, 0);
while ((my $i = index($data, $src, $pos)) >= 0) {
    substr($data, $i, length($src), $dst);
    $pos = $i + length($src);
    $n++;
}
if ($n == 0) { print "0\n"; exit 0; }
my @st = stat($path) or die "stat: $!\n";
my $tmp = "$path.agtmp.$$";
open(my $out, ">", $tmp) or die "tmp: $!\n";
binmode($out);
print {$out} $data or do { close($out); unlink($tmp); die "write: $!\n" };
close($out) or do { unlink($tmp); die "close: $!\n" };
chmod($st[2] & 07777, $tmp);
chown($st[4], $st[5], $tmp);
rename($tmp, $path) or do { unlink($tmp); die "rename: $!\n" };
print "$n\n";
ENDPERL
)

# ------------------------------------------------------------------ perl: JS IDE
# Порт patch_ide.rs. В символьных классах \$ — литеральный
# доллар JS-идентификатора, иначе perl съест $0.
PERL_JS=$(cat <<'ENDPERL'
use strict; use warnings;
use File::Copy qw(copy);

my ($mode, $path) = @ARGV;
my $MARKER = "// UNLOCKED";
my $FENCE  = "/*[AG_EXT_PATCHED]*/";
my $BAK    = ".ag_backup";

my $IDE_RE = qr/async\s+([A-Za-z_\$0-9]+)\(([A-Za-z_\$0-9]+)\)\s*\{\s*if\(this\.([A-Za-z_\$0-9]+)\.send\(\{type:[A-Za-z_\$0-9]+\.isGcpTos\?"GCP_SIGN_IN":"SIGN_IN"\}\),this\.([A-Za-z_\$0-9]+)\.resetIsTierGCPTos\(\),this\.[A-Za-z_\$0-9]+\.isGoogleInternal\)\{try\{await this\.([A-Za-z_\$0-9]+)\.loadCodeAssist\([A-Za-z_\$0-9]+\);const\{settings:([A-Za-z_\$0-9]+),userTier:([A-Za-z_\$0-9]+)\}=await this\.refreshUserStatus\([A-Za-z_\$0-9]+\),([A-Za-z_\$0-9]+)=([A-Za-z_\$0-9]+)\([A-Za-z_\$0-9]+\);this\.([A-Za-z_\$0-9]+)\.pushUpdate\([A-Za-z_\$0-9]+\),this\.[A-Za-z_\$0-9]+\.send\(\{type:"AUTH_SUCCESS",tokenInfo:[A-Za-z_\$0-9]+\}\),this\.([A-Za-z_\$0-9]+)\.fire\(\{settings:[A-Za-z_\$0-9]+,userTier:[A-Za-z_\$0-9]+\}\)\}catch\(([A-Za-z_\$0-9]+)\)\{.*?(?:return\}|return;\s*\})/s;

my $EXT_RE = qr/const t=await ([A-Za-z_\$][A-Za-z_\$0-9.]*)\.UserStatus\.getUserStatus\(\);if\(!t\)return\[\];const n=\(0,([A-Za-z_\$][A-Za-z_\$0-9.]*)\)\(t,([A-Za-z_\$][A-Za-z_\$0-9.]*)\),\{email:([A-Za-z_\$][A-Za-z_\$0-9]*),name:([A-Za-z_\$][A-Za-z_\$0-9]*)\}=n;return""===([A-Za-z_\$0-9]*)\?\[\]:/;

sub is_ext { $path =~ m{/extension\.js$} }
sub has_marker {
    my ($c) = @_;
    $c =~ s/\s+\z//;
    return 0 unless length $c;
    my $last = (split /\n/, $c)[-1];
    $last =~ s/^\s+//;
    return $last =~ /^\Q$MARKER\E/;
}
sub stacked { $_[0] =~ /\/\*\[AG_PATCHED\]\*\/|\[AG_PROXY_HOOK\]/ }
sub slurp {
    open my $fh, "<:raw", $_[0] or return;
    local $/;
    my $d = <$fh>;
    close $fh;
    return $d;
}
sub write_atomic {
    my ($p, $text) = @_;
    my @st = stat($p) or die "stat: $!\n";
    my $tmp = "$p.agtmp.$$";
    open my $out, ">:raw", $tmp or die "tmp: $!\n";
    print {$out} $text or do { close $out; unlink $tmp; die "write: $!\n" };
    close $out or do { unlink $tmp; die "close: $!\n" };
    chmod($st[2] & 07777, $tmp);
    chown($st[4], $st[5], $tmp);
    rename($tmp, $p) or do { unlink $tmp; die "rename: $!\n" };
}
sub backup_once {
    my $bak = $path . $BAK;
    copy($path, $bak) unless -e $bak;
}

sub classify {
    my $c = slurp($path);
    return "unreadable" unless defined $c;
    if (is_ext()) {
        return "patched"   if index($c, $FENCE) >= 0;
        return "unpatched" if $c =~ $EXT_RE;
        return "missing";
    }
    return "stacked"   if stacked($c);
    return "patched"   if has_marker($c);
    return "unpatched" if $c =~ $IDE_RE;
    return "missing";
}

sub patch_ide {
    my ($c) = @_;
    return unless $c =~ $IDE_RE;
    my ($start, $end) = ($-[0], $+[0]);
    my ($fname, $var_t, $var_t_send, $var_y) = ($1, $2, $3, $4);
    my ($var_i, $var_func, $var_f, $var_h) = ($8, $9, $10, $11);
    my $payload = join "",
        "async $fname($var_t){\n",
        "    this.$var_t_send.send({type:$var_t.isGcpTos?\"GCP_SIGN_IN\":\"SIGN_IN\"});\n",
        "    this.$var_y.resetIsTierGCPTos();\n",
        "    try {\n",
        "        try { await this.$var_y.loadCodeAssist($var_t); } catch(_) {}\n",
        "        try { await this.$var_y.onboardUser(\"standard-tier\", $var_t); } catch(_) {\n",
        "            try { await this.$var_y.onboardUser(\"free-tier\", $var_t); } catch(__) {}\n",
        "        }\n",
        "        let __res = { settings: {}, userTier: { id: \"pro\", description: \"Pro\" } };\n",
        "        try { __res = await this.refreshUserStatus($var_t); } catch(_) {}\n",
        "        const $var_i = $var_func($var_t);\n",
        "        try { this.$var_f.pushUpdate($var_i); } catch(_) {}\n",
        "        this.$var_t_send.send({type:\"AUTH_SUCCESS\",tokenInfo:$var_t});\n",
        "        this.$var_h.fire({settings:__res.settings, userTier:__res.userTier});\n",
        "    } catch(e) {}\n",
        "    return;\n";
    my $new = substr($c, 0, $start) . $payload . substr($c, $end);
    $new .= "\n" unless $new =~ /\n\z/;
    return $new . $MARKER . "\n";
}

sub patch_ext {
    my ($c) = @_;
    return unless $c =~ $EXT_RE;
    my ($ns, $p2, $dz7, $email, $name) = ($1, $2, $3, $4, $5);
    my $repl =
        "const t=await $ns.UserStatus.getUserStatus();" .
        "let $email=\"\",$name=\"\";" .
        "try{if(t){const n=(0,$p2)(t,$dz7);" .
        "$email=n.email||\"\";$name=n.name||\"\";}}catch(_){}" .
        "if($email===\"\"){$email=\"antigravity-user\";$name=\"User\";}" .
        "return false?[]:";
    my $new = $c;
    $new =~ s/$EXT_RE/$repl/;
    return if $new eq $c;
    return "$FENCE\n$new\n$MARKER\n";
}

if ($mode eq "status") { print classify(), "\n"; exit 0; }

if ($mode eq "patch") {
    my $st = classify();
    if ($st eq "patched") { print "already\n"; exit 0; }
    print "$st\n" and exit 0 if $st eq "stacked" || $st eq "missing" || $st eq "unreadable";
    my $c = slurp($path);
    my $new = is_ext() ? patch_ext($c) : patch_ide($c);
    if (!defined $new) { print "missing\n"; exit 0; }
    backup_once();
    write_atomic($path, $new);
    print "ok\n";
    exit 0;
}

if ($mode eq "unpatch") {
    my $bak = $path . $BAK;
    if (-e $bak) {
        my $text = slurp($bak);
        die "backup unreadable\n" unless defined $text;
        write_atomic($path, $text);
        unlink $bak;
        print "ok\n";
        exit 0;
    }
    my $c = slurp($path);
    die "unreadable\n" unless defined $c;
    my $changed = 0;
    if (index($c, $FENCE) == 0) {
        $c = substr($c, length($FENCE));
        $c =~ s/^\n//;
        $changed = 1;
    }
    if (has_marker($c)) {
        $c =~ s/\s+\z//;
        my $nl = rindex($c, "\n");
        $c = $nl >= 0 ? substr($c, 0, $nl) . "\n" : "";
        $changed = 1;
    }
    if ($changed) { write_atomic($path, $c); print "marker-only\n"; }
    else { print "already\n"; }
    exit 0;
}

die "unknown mode\n";
ENDPERL
)

sig_counts() { perl -e "$PERL_BIN" count "$1" 2>/dev/null; }
sig_apply()  { perl -e "$PERL_BIN" "$2" "$1"; }
is_native()  { [ "$(perl -e "$PERL_BIN" native "$1" 2>/dev/null)" = "1" ]; }
js_tool()    { perl -e "$PERL_JS" "$1" "$2"; }
canon()      { perl -MCwd=realpath -e 'print realpath($ARGV[0]) // $ARGV[0]' "$1" 2>/dev/null || echo "$1"; }

# ------------------------------------------------------------------ discovery
CANDIDATES=""
JS_CANDIDATES=""
NL='
'

add_to() {
  local var="$1" f="$2" real list
  [ -f "$f" ] || return 0
  case "$f" in *.agtmp*|*.ag_backup) return 0;; esac
  real=$(canon "$f")
  eval "list=\$$var"
  case "$NL$list" in *"$NL$real$NL"*) return 0;; esac
  eval "$var=\"\$list\$real\$NL\""
}

add_candidate() {
  local f="$1"
  [ -f "$f" ] || return 0
  case "$f" in *.agtmp*|*.ag_backup) return 0;; esac
  is_native "$f" || return 0
  add_to CANDIDATES "$f"
}

add_js() { add_to JS_CANDIDATES "$1"; }

scan_dir() {
  local d="$1" f
  [ -d "$d" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && add_candidate "$f"
  done <<EOF
$(find "$d" -maxdepth "$2" -type f \( -name 'language_server*' -o -name 'agy' -o -name 'agy_*' \) ! -name '*.agtmp*' ! -name '*.ag_backup' 2>/dev/null)
EOF
}

# Корень установки: бинари + JS IDE, если они там лежат.
add_install() {
  local root="$1"
  [ -d "$root" ] || return 0
  case "$root" in /snap/*|/var/lib/snapd/*) return 0;; esac
  scan_dir "$root" 8
  add_js "$root/Contents/Resources/app/out/main.js"
  add_js "$root/Contents/Resources/app/extensions/antigravity/dist/extension.js"
  add_js "$root/resources/app/out/main.js"
  add_js "$root/resources/app/extensions/antigravity/dist/extension.js"
}

collect_candidates() {
  CANDIDATES=""
  JS_CANDIDATES=""
  local b d p name

  if [ "$IS_DARWIN" -eq 1 ]; then
    for b in /Applications/*[Aa]ntigravity*.app "$USER_HOME"/Applications/*[Aa]ntigravity*.app; do
      add_install "$b"
    done
  else
    for d in /opt /usr/share /usr/lib /usr/local /usr/local/share \
             "$USER_HOME/.local/share" "$USER_HOME"; do
      [ -d "$d" ] || continue
      for name in Antigravity "Antigravity IDE" antigravity antigravity-ide; do
        add_install "$d/$name"
      done
      # Имя, которое не захардкодили (как scan_antigravity_dirs в оригинале).
      for b in "$d"/*[Aa]ntigravity*; do
        add_install "$b"
      done
    done
    add_install "$USER_HOME/.agy"
    add_install "$USER_HOME/.agy/bin"
    add_install "$USER_HOME/.local/share/agy/bin"
  fi

  for p in "$USER_HOME/.gemini/bin/agy" "$USER_HOME/.agy/bin/agy" \
           "$USER_HOME/.local/bin/agy" "$USER_HOME/bin/agy" \
           /usr/local/bin/agy /usr/bin/agy /opt/homebrew/bin/agy \
           "$(command -v agy 2>/dev/null)"; do
    [ -n "$p" ] || continue
    case "$p" in /snap/*) continue;; esac
    add_candidate "$p"
  done

  for d in "$USER_HOME"/.vscode/extensions "$USER_HOME"/.vscode-insiders/extensions \
           "$USER_HOME"/.vscode-server/extensions "$USER_HOME"/.cursor/extensions \
           "$USER_HOME"/.cursor-server/extensions "$USER_HOME"/.windsurf/extensions \
           "$USER_HOME"/.trae/extensions "$USER_HOME"/.vscodium/extensions \
           "$USER_HOME"/.positron/extensions "$USER_HOME"/.antigravity/extensions \
           "$USER_HOME"/.antigravity-ide/extensions; do
    [ -d "$d" ] || continue
    for b in "$d"/*[Aa]ntigravity*; do
      [ -d "$b" ] && scan_dir "$b" 4
    done
  done
}

label_for() {
  local f="$1" bundle
  bundle=$(bundle_of "$f")
  if [ -n "$bundle" ]; then
    case "$f" in
      */out/main.js) echo "$(basename "$bundle" .app) → JS auth (out/main.js)" ;;
      */dist/extension.js) echo "$(basename "$bundle" .app) → JS extension.js" ;;
      *) echo "$(basename "$bundle" .app) → $(basename "$f")" ;;
    esac
    return
  fi
  case "$f" in
    */.gemini/bin/agy) echo "CLI agy (он же бэкенд VS Code-расширения)" ;;
    */out/main.js)     echo "IDE → JS auth (out/main.js)" ;;
    */dist/extension.js) echo "IDE → JS extension.js" ;;
    */extensions/*)    echo "расширение $(echo "${f#*/extensions/}" | cut -d/ -f1)" ;;
    *)                 echo "CLI $(basename "$f")" ;;
  esac
}

# ------------------------------------------------------------------ состояние
state_of() {
  local counts
  counts=$(sig_counts "$1")
  [ -z "$counts" ] && { echo "unreadable 0 0"; return; }
  local a b; a=${counts%% *}; b=${counts##* }
  if   [ "$b" -gt 0 ] && [ "$a" -eq 0 ]; then echo "patched $a $b"
  elif [ "$a" -gt 0 ]; then echo "unpatched $a $b"
  else echo "missing 0 0"
  fi
}

kind_of() {
  case "$1" in
    *.js) js_tool status "$1" ;;
    *) state_of "$1" | awk '{print $1}' ;;
  esac
}

all_targets() { printf "%s" "$CANDIDATES$JS_CANDIDATES"; }

writable() { [ -w "$1" ] && [ -w "$(dirname "$1")" ]; }

perm_hint() {
  local f="$1" owner
  owner=$(file_owner "$f")
  if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ] && [ "$(id -u)" -ne 0 ]; then
    echo "файл другого пользователя — перезапусти через sudo"
  elif [ "$IS_DARWIN" -eq 1 ] && [ -n "$(bundle_of "$f")" ]; then
    echo "macOS защищает приложение: Системные настройки → Конфиденциальность и безопасность → Управление приложениями → включи свой терминал, перезапусти его и повтори"
  else
    echo "нет прав на запись — перезапусти через sudo"
  fi
}

# ------------------------------------------------------------------ подпись (только macOS)
resign_file() {
  [ "$IS_DARWIN" -eq 1 ] || return 0
  xattr -d com.apple.quarantine "$1" 2>/dev/null
  if ! codesign --force --sign - "$1" >/dev/null 2>&1; then
    err "codesign не смог подписать $(tilde "$1") — бинарь не запустится"
    warn "    поставь Command Line Tools (xcode-select --install) и повтори"
    return 1
  fi
}

resign_bundle() {
  local bundle="$1"
  [ "$IS_DARWIN" -eq 1 ] || return 0
  [ -n "$bundle" ] || return 0
  info "Переподписываю бандл (это займёт минуту): $(tilde "$bundle")"
  xattr -dr com.apple.quarantine "$bundle" 2>/dev/null
  if codesign --force --deep --sign - "$bundle" >/dev/null 2>&1; then
    ok "Бандл переподписан ad-hoc — запуск из Finder/Launchpad работает"
  else
    err "Не удалось переподписать $(tilde "$bundle")"
    warn "Системные настройки → Конфиденциальность и безопасность → Управление"
    warn "приложениями → включи свой терминал и повтори патч."
  fi
}

bundle_of() {
  case "$1" in
    *.app/*) echo "${1%%.app/*}.app" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------------ процессы
stop_servers() {
  pkill -f "language_server" 2>/dev/null
  pkill -f "/agy" 2>/dev/null
  sleep 1
}

running_apps() {
  local f b seen=""
  if [ "$IS_DARWIN" -eq 1 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b=$(bundle_of "$f"); [ -n "$b" ] || continue
      case "$NL$seen" in *"$NL$b$NL"*) continue;; esac
      if pgrep -f "$b/Contents/MacOS/" >/dev/null 2>&1; then
        seen="$seen$b$NL"
        echo "$b"
      fi
    done <<EOF
$(all_targets)
EOF
  else
    if pgrep -af -i 'antigravity|language_server' 2>/dev/null | grep -v 'ag_patcher' >/dev/null; then
      echo "Antigravity (linux)"
    fi
  fi
}

confirm() {
  [ -n "${AG_YES:-}" ] && return 0
  local a
  printf "%b" "${C_WARN}[?]${C_N} $1 [y/N]: "
  read -r a </dev/tty 2>/dev/null || return 1
  case "$a" in y|Y|д|Д) return 0;; *) return 1;; esac
}

# ------------------------------------------------------------------ отчёт
report_one() {
  local f="$1" kind extra=""
  kind=$(kind_of "$f")
  case "$kind" in
    patched)   ok   "пропатчен   — $(label_for "$f")" ;;
    unpatched) warn "НЕ пропатчен — $(label_for "$f")" ;;
    missing)   warn "сигнатуры нет (новая сборка?) — $(label_for "$f")" ;;
    stacked)   err  "старый сторонний JS-патч — переустанови IDE, потом повтори: $(label_for "$f")" ;;
    *)         err  "не читается — $(label_for "$f")" ;;
  esac
  case "$f" in
    *.js) extra="JS $(basename "$f")" ;;
    *)
      local st a b
      st=$(state_of "$f"); a=$(echo "$st" | awk '{print $2}'); b=$(echo "$st" | awk '{print $3}')
      extra="ineligible: $a, inexigible: $b"
      ;;
  esac
  dim "      $(tilde "$f")   [$extra]"
  writable "$f" || say "      ${C_WARN}запись недоступна: $(perm_hint "$f")${C_N}"
}

report() {
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    report_one "$f"
  done <<EOF
$(all_targets)
EOF
  [ "$n" -eq 0 ] && return 1
  return 0
}

# ------------------------------------------------------------------ действия
note_bundle() {
  local b="$1"
  [ -n "$b" ] || return 0
  case "$NL$bundles" in *"$NL$b$NL"*) ;; *) bundles="$bundles$b$NL" ;; esac
}

apply_one() {
  local mode="$1" f="$2" kind out expect
  kind=$(kind_of "$f")
  if [ "$kind" != "$want" ]; then
    case "$kind" in
      patched)   [ "$mode" = "patch" ]   && dim "  пропускаю (уже пропатчен): $(tilde "$f")" ;;
      unpatched) [ "$mode" = "unpatch" ] && dim "  пропускаю (уже стоковый): $(tilde "$f")" ;;
      missing)   warn "сигнатуры нет, не трогаю: $(tilde "$f")" ;;
      stacked)   err  "старый JS-патч в $(tilde "$f") — переустанови IDE" ; failed=$((failed+1)) ;;
      *)         err  "не читается: $(tilde "$f")" ; failed=$((failed+1)) ;;
    esac
    return 0
  fi

  case "$f" in
    *.js)
      out=$(js_tool "$mode" "$f" 2>&1)
      if [ "$out" != "ok" ] && [ "$out" != "marker-only" ]; then
        err "JS $(tilde "$f"): $out"
        failed=$((failed+1))
        return 0
      fi
      ;;
    *)
      out=$(sig_apply "$f" "$mode" 2>&1)
      if [ $? -ne 0 ] || ! echo "$out" | grep -qE '^[0-9]+$'; then
        err "не удалось записать $(tilde "$f"): $out"
        failed=$((failed+1))
        return 0
      fi
      resign_file "$f" || failed=$((failed+1))
      ;;
  esac

  [ "$mode" = "patch" ] && expect="patched" || expect="unpatched"
  kind=$(kind_of "$f")
  if [ "$kind" = "$expect" ]; then
    ok "$([ "$mode" = "patch" ] && echo "пропатчен" || echo "откачен"): $(tilde "$f")"
    changed=$((changed+1))
    note_bundle "$(bundle_of "$f")"
  else
    err "проверка после записи не сошлась: $(tilde "$f") (состояние: $kind)"
    failed=$((failed+1))
  fi
}

run_patch() {
  local mode="$1" f kind want out changed=0 failed=0 bundles="" b
  case "$mode" in
    patch)   want="unpatched" ;;
    unpatch) want="patched"   ;;
  esac

  local blocked=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kind=$(kind_of "$f"); [ "$kind" = "$want" ] || continue
    if ! writable "$f"; then
      blocked=$((blocked+1))
      err "$(tilde "$f")"
      warn "    $(perm_hint "$f")"
    fi
  done <<EOF
$(all_targets)
EOF
  if [ "$blocked" -gt 0 ]; then
    err "Целей недоступно на запись: $blocked. Ничего не менял."
    return 1
  fi

  local live; live=$(running_apps)
  if [ -n "$live" ]; then
    warn "Сейчас запущено:"
    while IFS= read -r b; do [ -n "$b" ] && dim "      $(tilde "$b")"; done <<EOF
$live
EOF
    warn "Правка файлов работающего приложения может его уронить."
    confirm "Закрыть Antigravity и продолжить?" || { info "Отменено."; return 1; }
    if [ "$IS_DARWIN" -eq 1 ]; then
      while IFS= read -r b; do [ -n "$b" ] && pkill -f "$b/Contents/MacOS/" 2>/dev/null; done <<EOF
$live
EOF
    else
      pkill -f -i 'Antigravity|antigravity-ide' 2>/dev/null
    fi
    sleep 2
  fi
  stop_servers

  while IFS= read -r f; do
    [ -n "$f" ] && apply_one "$mode" "$f"
  done <<EOF
$(all_targets)
EOF

  while IFS= read -r b; do
    [ -n "$b" ] && resign_bundle "$b"
  done <<EOF
$bundles
EOF

  if [ "$changed" -eq 0 ] && [ "$failed" -eq 0 ]; then
    info "Менять нечего — всё уже в нужном состоянии."
  else
    info "Изменено файлов: $changed, ошибок: $failed"
    if [ "$mode" = "patch" ] && [ "$changed" -gt 0 ]; then
      info "Запусти Antigravity и войди в Google-аккаунт."
      info "После обновления патч затирается — просто прогони скрипт снова."
    elif [ "$changed" -gt 0 ]; then
      info "JS восстановлен из .ag_backup; бинари — побайтово."
      [ "$IS_DARWIN" -eq 1 ] && info "Подпись на macOS осталась ad-hoc — на запуск не влияет."
    fi
  fi
  [ "$failed" -eq 0 ]
}

# ------------------------------------------------------------------ main
case "$OS" in Darwin|Linux) ;; *) err "Только macOS и Linux."; exit 1 ;; esac
command -v perl >/dev/null || { err "Нужен perl (штатный в macOS и Ubuntu)."; exit 1; }

scan() {
  info "Ищу установки Antigravity…"
  collect_candidates
  if [ -z "$CANDIDATES" ] && [ -z "$JS_CANDIDATES" ]; then
    err "Ничего не найдено."
    if [ "$IS_DARWIN" -eq 1 ]; then
      warn "Ожидаются: /Applications/Antigravity.app, /Applications/Antigravity IDE.app,"
    else
      warn "Ожидаются: /opt/Antigravity, /usr/share/antigravity, ~/.local/share/Antigravity,"
    fi
    warn "CLI ~/.gemini/bin/agy (его ставит и VS Code-расширение google.google-antigravity)."
    return 1
  fi
  say ""
  report
  say ""
  return 0
}

case "${1:-}" in
  patch)   scan || exit 1; run_patch patch;   exit $? ;;
  unpatch) scan || exit 1; run_patch unpatch; exit $? ;;
  status)  scan; exit $? ;;
  -h|--help|help)
    say "Использование: bash $0 [patch|unpatch|status]"
    say "  patch    — пропатчить все найденные бинари и JS IDE"
    say "  unpatch  — откатить патч"
    say "  status   — только показать состояние"
    say "  без аргументов — интерактивное меню"
    say "Нужны bash и perl. macOS и Linux."
    exit 0 ;;
  "") ;;
  *) err "Неизвестная команда: $1 (см. --help)"; exit 1 ;;
esac

scan
while true; do
  say "===== Antigravity patcher (macOS / Linux) ====="
  say " 1) Пропатчить всё найденное"
  say " 2) Откатить патч"
  say " 0) Выход"
  printf "Выбор: "
  read -r choice || { say ""; exit 0; }
  say ""
  case "$choice" in
    1) run_patch patch;   say ""; scan ;;
    2) run_patch unpatch; say ""; scan ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню"; say "" ;;
  esac
done
