#!/usr/bin/env bash
# Mock external commands via PATH prepend.
# Each mock logs its invocation to a .calls file for verification.

ORIGINAL_PATH=""

# setup_mock_path <tmpdir>
# Creates a mock bin directory and prints its path. Does NOT modify PATH.
#
# Root cause of the old behavior's bug: it ran `export PATH=...` inside this
# function, but every caller invokes it as `mock_bin=$(setup_mock_path ...)`
# — a command substitution, which bash runs in a SUBSHELL. That subshell's
# PATH mutation dies with the subshell; the caller's PATH is never touched.
# hide_command's stub files land on disk correctly, but the "masked" command
# stays fully resolvable via the caller's real, unmutated PATH — masked
# tests silently exercise the REAL command instead of the stub and can pass
# for the wrong reason (verified: on a box with a real python3 installed,
# `mock_bin=$(setup_mock_path "$T"); hide_command "$mock_bin" python3` left
# python3 fully resolvable afterward).
#
# Documented usage (mutate PATH in the CALLER's shell, not inside a
# substitution):
#   ORIGINAL_PATH="$PATH"
#   mock_bin=$(setup_mock_path "$tmpdir")
#   hide_command "$mock_bin" "jq"
#   PATH="$mock_bin:$PATH"
#   ... test code ...
#   restore_path
setup_mock_path() {
  local tmpdir="$1"
  local mock_bin="$tmpdir/mock-bin"
  mkdir -p "$mock_bin"
  echo "$mock_bin"
}

# restore_path
# Restores PATH saved in ORIGINAL_PATH by the caller before it mutated PATH
# (see setup_mock_path's documented usage pattern above).
restore_path() {
  if [ -n "$ORIGINAL_PATH" ]; then
    export PATH="$ORIGINAL_PATH"
    ORIGINAL_PATH=""
  fi
}

# create_mock_git <mock_bin_dir> [behavior]
# Behaviors: "clean" (default), "dirty", "has-lessons"
create_mock_git() {
  local mock_bin="$1"
  local behavior="${2:-clean}"
  cat > "$mock_bin/git" << MOCKEOF
#!/usr/bin/env bash
echo "git \$*" >> "$mock_bin/git.calls"
case "\$1" in
  rev-parse)
    case "\$2" in
      --git-dir) echo ".git" ;;
      --abbrev-ref) echo "master" ;;
      --show-toplevel) echo "/tmp/test-project" ;;
      HEAD) echo "abc1234" ;;
    esac
    ;;
  remote)
    echo "https://github.com/test/repo.git"
    ;;
  log)
    echo "feat: test commit message"
    ;;
  diff)
    case "$behavior" in
      has-lessons)
        echo "+- New lesson learned"
        echo "+- Another lesson"
        ;;
      *) echo "" ;;
    esac
    ;;
  status)
    case "$behavior" in
      dirty) echo " M src/test.ts" ;;
      *) echo "" ;;
    esac
    ;;
  -C)
    shift  # consume -C flag
    shift  # consume directory argument
    case "\$1" in
      # A mocked repo enumerates NO commits: the git-derived commit sensor
      # (calibration T1) runs `git -C <dir> log --since=...` on EVERY Bash
      # observation, so a canned subject here would forge a phantom commit
      # event in every mock-git suite. (The old canned "feat: test commit"
      # served the deleted lexical path's subject fetch.)
      log) : ;;
      diff)
        case "$behavior" in
          has-lessons)
            echo "+- New lesson"
            ;;
          *) echo "" ;;
        esac
        ;;
      rev-list) echo "0" ;;
      check-ignore) exit 1 ;;
      *) echo "" ;;
    esac
    ;;
  *) echo "" ;;
esac
MOCKEOF
  chmod +x "$mock_bin/git"
}

# create_mock_gh <mock_bin_dir> [ci_status]
# ci_status: "success" (default), "failure"
create_mock_gh() {
  local mock_bin="$1"
  local ci_status="${2:-success}"
  cat > "$mock_bin/gh" << MOCKEOF
#!/usr/bin/env bash
echo "gh \$*" >> "$mock_bin/gh.calls"
case "\$1" in
  run)
    case "$ci_status" in
      failure) echo '[{"status":"completed","conclusion":"failure","name":"CI"}]' ;;
      *) echo '[{"status":"completed","conclusion":"success","name":"CI"}]' ;;
    esac
    ;;
  pr)
    echo '[]'
    ;;
  *)
    echo '[]'
    ;;
esac
MOCKEOF
  chmod +x "$mock_bin/gh"
}

# hide_command <mock_bin_dir> <command_name>
# Creates a stub that exits 127 (simulates command not found).
hide_command() {
  local mock_bin="$1" cmd="$2"
  cat > "$mock_bin/$cmd" << 'MOCKEOF'
#!/usr/bin/env bash
exit 127
MOCKEOF
  chmod +x "$mock_bin/$cmd"
}

# get_mock_calls <mock_bin_dir> <command_name>
# Returns the call log for a mocked command.
get_mock_calls() {
  local mock_bin="$1" cmd="$2"
  cat "$mock_bin/${cmd}.calls" 2>/dev/null || echo ""
}

# create_mock_date <mock_bin_dir> <day_of_year>
# Creates a mock date that returns a specific day-of-year for +%j,
# but passes through to real date for all other formats.
#
# Root cause of the old recursion bug: `which date` searches the CURRENT
# $PATH. On the 2nd+ call within a suite, mock_bin is typically ALREADY
# prepended to PATH (the caller applied it after the 1st create_mock_date
# call) — so `which date` resolves to the FIRST mock's own script, which
# gets baked into the regenerated script as ITS "real" passthrough target.
# Any non-"+%j" invocation then execs the mock, which execs itself, forever
# (verified: this actually forkbombed hundreds of orphaned bash processes in
# testing — see task report).
#
# Fix: resolve via `command -v -p`, which searches a POSIX-guaranteed
# DEFAULT path (not the current $PATH), so it can't resolve to mock_bin
# regardless of call order or how many times mock_bin has been on PATH.
# Falls back to a current-PATH search only if `-p` resolution is
# unavailable, and explicitly rejects a self-referential result either way
# — belt-and-suspenders against ever baking in a recursive reference.
create_mock_date() {
  local mock_bin="$1"
  local day_of_year="$2"
  local real_date
  real_date=$(command -v -p date 2>/dev/null || true)
  if [ -z "$real_date" ] || [ "$real_date" = "$mock_bin/date" ]; then
    real_date=$(which date 2>/dev/null || echo "/usr/bin/date")
  fi
  if [ "$real_date" = "$mock_bin/date" ]; then
    real_date="/usr/bin/date"
  fi
  cat > "$mock_bin/date" << MOCKEOF
#!/usr/bin/env bash
echo "date \$*" >> "$mock_bin/date.calls"
for arg in "\$@"; do
  if [ "\$arg" = "+%j" ]; then
    echo "$day_of_year"
    exit 0
  fi
done
# Pass through to real date for other formats
"$real_date" "\$@"
MOCKEOF
  chmod +x "$mock_bin/date"
}
