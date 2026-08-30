# Bash Tricks — Lessons from Building dev-sandbox

Practical bash patterns discovered while building a ~1800 line single-file script.
Each trick includes the problem it solves, the solution, and the gotcha that makes it non-obvious.

---

# Part 1: Bash Fundamentals

Things that trip up developers coming from Python, JavaScript, or other languages.

---

## Everything is a Command

In Python, `if`, `for`, `while` are language keywords with special syntax. In bash, **everything is a command** that returns an exit code.

```bash
# "if" doesn't evaluate an expression — it runs a command
# and checks its exit code

if grep -q "error" logfile; then
    echo "Found errors"
fi

# grep returns 0 (found) or 1 (not found)
# "if" branches based on that exit code
```

Even `[[ ]]` and `[ ]` are commands:

```bash
# [[ is a bash built-in command that returns 0 or 1
[[ "hello" == "hello" ]]
echo $?    # 0 (true)

[[ "hello" == "world" ]]
echo $?    # 1 (false)

# [ is actually /usr/bin/test (or a built-in)
[ -f /etc/passwd ]
echo $?    # 0 (file exists)
```

---

## Exit Codes: 0 is True, Everything Else is False

Opposite from most languages where 0 is false and 1 is true.

```bash
# In Python:  0 = False, 1 = True
# In bash:    0 = success/true, 1+ = failure/false

true       # built-in command, exit code 0
false      # built-in command, exit code 1

if true; then echo "yes"; fi     # yes
if false; then echo "yes"; fi    # (nothing)
```

**Why?** Because there's one way to succeed but many ways to fail. Exit code 0 = "everything went fine". Exit codes 1-255 = different types of failures:

```bash
grep -q "pattern" file
# 0 = found
# 1 = not found
# 2 = file doesn't exist

curl https://example.com
# 0 = success
# 6 = couldn't resolve host
# 7 = couldn't connect
# 28 = timeout
```

**`$?`** holds the exit code of the last command:

```bash
ls /nonexistent 2>/dev/null
echo $?    # 2 (no such file)

ls /tmp
echo $?    # 0 (success)
```

---

## Running Commands

No function calls, no method chaining — just commands with arguments separated by spaces:

```bash
# Every line is: command arg1 arg2 arg3 ...
cp source.txt dest.txt
grep -r "pattern" /path
podman run --rm -it image /bin/bash

# Strings don't need quotes unless they contain spaces or special chars
echo hello                    # works
echo hello world              # works (two args to echo, same result)
echo "hello world"            # one arg with space

# Variables
name="tomaz"
echo "Hello $name"            # Hello tomaz
echo 'Hello $name'            # Hello $name  (single quotes = literal)
```

**Command chaining:**

```bash
# ; — run next regardless
mkdir dir; cd dir

# && — run next only if previous succeeded (exit code 0)
mkdir dir && cd dir

# || — run next only if previous failed (exit code non-zero)
mkdir dir || echo "Failed to create dir"

# | — pipe stdout to next command's stdin
cat file.txt | grep "error" | wc -l
```

---

## Quoting: The Source of Most Bugs

Three types of quoting, each behaves differently:

```bash
name="world"

# Double quotes — variables expanded, spaces preserved
echo "Hello $name"           # Hello world
echo "path with spaces"      # one argument

# Single quotes — nothing expanded, everything literal
echo 'Hello $name'           # Hello $name
echo '$HOME is ~/dir'        # $HOME is ~/dir

# No quotes — variables expanded, word splitting on spaces
file="my document.txt"
cat $file                    # BAD: runs cat with TWO args: "my" and "document.txt"
cat "$file"                  # GOOD: runs cat with ONE arg: "my document.txt"
```

**Rule of thumb: always double-quote variables.** The only exception is when you intentionally want word splitting (rare).

```bash
# BAD
if [ -f $file ]; then        # breaks if $file has spaces or is empty
for f in $files; do           # intentional splitting, but fragile

# GOOD
if [ -f "$file" ]; then      # always works
for f in "${files[@]}"; do    # iterate array properly
```

---

## `[ ]` vs `[[ ]]`

`[ ]` is POSIX (works everywhere). `[[ ]]` is bash-specific but safer:

```bash
# [ ] — old style, more pitfalls
[ -f "$file" ]                # file exists?
[ "$a" = "$b" ]               # string comparison (single =)
[ "$x" -eq 5 ]                # numeric comparison

# [[ ]] — bash style, recommended
[[ -f "$file" ]]              # file exists?
[[ "$a" == "$b" ]]            # string comparison (double ==)
[[ "$x" -eq 5 ]]              # numeric comparison
[[ "$name" == *.txt ]]         # glob matching (can't do in [ ])
[[ "$name" =~ ^[0-9]+$ ]]     # regex matching (can't do in [ ])
```

**Key difference:** `[[ ]]` doesn't word-split variables, so it's safer without quotes (but quote anyway for habit):

```bash
file=""
[ -f $file ]                  # Error! Becomes [ -f ] which is invalid
[[ -f $file ]]                # Fine — empty string handled correctly
```

---

## Variables and Types

Bash has no types. Everything is a string. Numbers are strings that happen to contain digits:

```bash
x=42                          # string "42"
y="hello"                     # string "hello"

# Arithmetic uses $(( )) or (( ))
result=$((x + 10))            # 52
((x++))                       # x is now 43

# String operations
${#y}                         # 5 (length)
${y^^}                        # HELLO (uppercase)
${y,,}                        # hello (lowercase)

# No boolean type — use strings
enabled=true
if [[ "$enabled" == "true" ]]; then
    echo "on"
fi
```

**Arrays:**

```bash
# Indexed array
fruits=(apple banana cherry)
echo "${fruits[0]}"           # apple
echo "${fruits[@]}"           # apple banana cherry
echo "${#fruits[@]}"          # 3 (length)
fruits+=(grape)               # append

# Iterate
for f in "${fruits[@]}"; do
    echo "$f"
done
```

**Associative arrays** (bash 4+):

```bash
declare -A config
config[port]=8080
config[host]="localhost"
echo "${config[port]}"        # 8080
```

---

## Loops

```bash
# For — iterate over list
for file in *.txt; do
    echo "Processing $file"
done

# For — iterate over array
for item in "${array[@]}"; do
    echo "$item"
done

# For — C-style
for ((i=0; i<10; i++)); do
    echo "$i"
done

# While — read lines from file
while IFS= read -r line; do
    echo "Line: $line"
done < file.txt

# While — read from command output
podman ps --format "{{.Names}}" | while read -r name; do
    echo "Container: $name"
done

# While — infinite loop with condition
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --verbose) VERBOSE=true; shift ;;
        *) break ;;
    esac
done
```

**Gotcha with pipes:** A pipe creates a subshell. Variables set inside `while` in a pipe are lost:

```bash
# BAD — count is always 0 after the loop
count=0
echo -e "a\nb\nc" | while read -r line; do
    ((count++))
done
echo "$count"    # 0! (pipe created subshell)

# GOOD — use process substitution
count=0
while read -r line; do
    ((count++))
done < <(echo -e "a\nb\nc")
echo "$count"    # 3
```

---

## Functions

```bash
# Define
greet() {
    local name="$1"           # $1 = first argument
    local greeting="${2:-Hello}"  # $2 with default
    echo "${greeting}, ${name}!"
}

# Call (no parentheses, just space-separated args)
greet "Tomaz"                 # Hello, Tomaz!
greet "Tomaz" "Hi"            # Hi, Tomaz!

# Capture output
message=$(greet "Tomaz")
echo "$message"               # Hello, Tomaz!

# Return values — exit codes, not values
is_even() {
    local n=$1
    (( n % 2 == 0 ))          # returns 0 (true) or 1 (false)
}

if is_even 4; then
    echo "even"               # even
fi
```

**`local` keyword:** Without `local`, variables are global — they leak out of functions and overwrite things:

```bash
# BAD
broken() {
    name="oops"               # overwrites global $name
}

# GOOD
safe() {
    local name="contained"    # only visible inside this function
}
```

**`local` only works inside functions.** In global scope, use `var=""` instead.

---

## Redirections

```bash
# stdout to file
echo "hello" > file.txt       # overwrite
echo "hello" >> file.txt      # append

# stderr to file
command 2> errors.log

# Both stdout and stderr
command > output.log 2>&1     # all to one file
command &> output.log         # bash shorthand (same thing)

# Discard output
command > /dev/null            # discard stdout
command 2> /dev/null           # discard stderr
command &> /dev/null           # discard both

# stderr to stdout (for piping errors)
command 2>&1 | grep "error"

# Input from string
grep "pattern" <<< "$variable"

# Heredoc — multi-line input
cat << EOF
Hello $name
This expands variables
EOF

cat << 'EOF'
Hello $name
This does NOT expand — literal $name
EOF
```

---

## Command Substitution

Capture command output in a variable:

```bash
# Modern syntax (nestable)
today=$(date +%Y-%m-%d)
files=$(ls *.txt)
count=$(wc -l < file.txt)

# Old syntax (backticks — avoid)
today=`date +%Y-%m-%d`       # harder to nest, harder to read

# Nested
dirname=$(basename $(dirname "$filepath"))

# In conditions
if [[ $(whoami) == "root" ]]; then
    echo "Running as root"
fi
```

---

## `set` Options

```bash
set -e          # Exit on any command failure (non-zero exit code)
set -u          # Error on unset variables (catches typos)
set -o pipefail # Pipe fails if ANY command in the pipe fails
                # Without this: `false | true` returns 0 (success!)

# Combined — the standard strict mode
set -euo pipefail
```

**`set -e` gotchas:**

```bash
set -e

# This kills the script if grep finds nothing!
grep "pattern" file            # exit 1 = script dies

# Safe alternatives
grep "pattern" file || true    # ignore failure
if grep -q "pattern" file; then  # check in condition (immune)
    echo "found"
fi
```

---

# Part 2: Advanced Patterns

Tricks from dev-sandbox that go beyond the basics.

---

## 1. Indirect Variable References

**Problem:** Read a variable whose name is constructed at runtime.

```bash
PROFILE_claude_SSH_PORT=2228
PROFILE_research_SSH_PORT=2229

profile="claude"
# How to read PROFILE_claude_SSH_PORT without eval?
```

**Solution:** `${!ref}` — indirect expansion.

```bash
get_profile_var() {
    local ref="PROFILE_${1}_${2}"
    echo "${!ref:-}"           # :-  returns empty if unset
}

port=$(get_profile_var "claude" "SSH_PORT")   # 2228
port=$(get_profile_var "research" "SSH_PORT") # 2229
port=$(get_profile_var "test" "SSH_PORT")     # (empty — not set)
```

**Gotcha:** Doesn't work for arrays. `${!ref}` on an array gives only the first element. For arrays, you need `${!ref}` with `[@]` suffix — see trick #2.

---

## 2. Indirect Array References

**Problem:** Read an array variable whose name is constructed at runtime.

```bash
PROFILE_claude_VOLUMES=(.claude .cache)
PROFILE_research_VOLUMES=(.gemini .cache .config)

profile="claude"
# How to get all elements?
```

**Solution:** Construct the reference with `[@]` and expand.

```bash
local ref="PROFILE_${profile}_VOLUMES[@]"
local vols=("${!ref}")

for v in "${vols[@]}"; do
    echo "$v"
done
```

**Gotcha:** If the array doesn't exist, `"${!ref}"` gives an error under `set -u`. Safer approach — check with `declare -p` first:

```bash
get_profile_array_ref() {
    local profile="$1" var="$2" target="$3"
    if [[ -n "$(declare -p "PROFILE_${profile}_${var}" 2>/dev/null)" ]]; then
        eval "${target}=(\"\${PROFILE_${profile}_${var}[@]}\")"
    elif [[ -n "$(declare -p "DEFAULT_${var}" 2>/dev/null)" ]]; then
        eval "${target}=(\"\${DEFAULT_${var}[@]}\")"
    else
        eval "${target}=()"
    fi
}

local vols=()
get_profile_array_ref "claude" "VOLUMES" vols
```

Yes, `eval` is used here. For indirect array assignment there's no clean alternative in bash.

---

## 3. `set -euo pipefail` and the `&&` Trap

**Problem:** `set -e` exits on any non-zero return. Seems safe, but:

```bash
set -e

[[ "$mode" == "locked" ]] && enable_firewall
# If mode is NOT "locked", the && returns exit code 1
# set -e kills the script!
```

**Solution:** Always use `if/then/fi` instead of `&&` for conditional execution:

```bash
# BAD — dies if condition is false
[[ "$mode" == "locked" ]] && enable_firewall

# GOOD — explicit if
if [[ "$mode" == "locked" ]]; then
    enable_firewall
fi
```

**Why:** `[[ false_condition ]] && action` returns the exit code of `[[` which is 1. Under `set -e`, any non-zero exit kills the script. `if/then/fi` is immune because bash treats the whole `if` construct as one statement.

---

## 4. Empty Arrays Under `set -u`

**Problem:** `set -u` (treat unset variables as errors) interacts badly with empty arrays in older bash:

```bash
set -u
local flags=()
echo "${flags[@]}"    # Error in bash < 4.4: unbound variable!
```

**Solution:** Use `"${flags[@]}"` — in bash 4.4+ (Fedora ships 5.x) this works correctly and expands to nothing. For compatibility, use `${flags[@]+"${flags[@]}"}`:

```bash
# Always safe — expands to nothing if empty
podman run "${flags[@]}" image     # bash 4.4+

# Compatible with older bash
podman run ${flags[@]+"${flags[@]}"} image
```

**Why this matters for dev-sandbox:** Optional flags are built as arrays and passed to podman. If SSH is off, `ssh_flags=()` must expand to nothing, not cause an error:

```bash
local ssh_flags=()
if [[ "$ssh_port" != "0" ]]; then
    ssh_flags+=(-p "127.0.0.1:${ssh_port}:22")
fi

podman run "${ssh_flags[@]}" "${env_flags[@]}" image
# If ssh_flags is empty, it vanishes. Only env_flags remain.
```

---

## 5. Parameter Expansion Tricks

**String splitting without external commands:**

```bash
hostport="host.containers.internal:1080"

host="${hostport%:*}"     # host.containers.internal  (remove shortest match from end)
port="${hostport#*:}"     # 1080                       (remove shortest match from start)

# With | separator (for wrappers config)
entry="claude|#!/bin/bash..."
name="${entry%%|*}"       # claude    (%% = longest match from end)
body="${entry#*|}"        # #!/bin/bash...
```

**Defaults:**

```bash
${var:-default}           # Use default if var is unset or empty
${var:+alternative}       # Use alternative if var IS set
${var:=default}           # Assign default if unset (side effect!)

# Practical use
ssh_port="${SSH_PORT_OVERRIDE:-${profile_port:-0}}"
# CLI override > profile setting > 0
```

**Tilde expansion in variables:**

```bash
ssh_key="~/.ssh/id_ed25519.pub"
# $ssh_key is literally "~/.ssh/..." — tilde NOT expanded

ssh_key="${ssh_key/#\~/$HOME}"
# Now it's "/home/tomaz/.ssh/id_ed25519.pub"
```

---

## 6. Building Commands with Arrays

**Problem:** Constructing complex commands with optional parts.

```bash
# BAD — string concatenation, breaks on spaces
cmd="podman run"
if [[ -n "$storage" ]]; then
    cmd="$cmd --root $storage"    # Breaks if $storage has spaces
fi
cmd="$cmd image"
$cmd                              # Word splitting disaster
```

**Solution:** Use arrays. Each element stays intact regardless of spaces:

```bash
local flags=()
flags+=(--name "${container_name}")
flags+=(--hostname "${profile}-sandbox")

if [[ "$ssh_port" != "0" ]]; then
    flags+=(-p "127.0.0.1:${ssh_port}:22")
fi

if [[ "$effective_net" == "locked" ]]; then
    flags+=(--cap-add NET_ADMIN)
fi

# Clean, no word splitting, spaces preserved
podman run "${flags[@]}" "$image"
```

**Why arrays beat strings:** Each `+=()` adds exactly one logical argument. `"${flags[@]}"` expands each element as a separate word. A path like `/mnt/my storage/data` stays as one argument.

---

## 7. IFS Tricks — Split and Join

**Split a comma-separated string into an array:**

```bash
IFS=',' read -ra destinations <<< "host:1080,host:22,host:443"

for dest in "${destinations[@]}"; do
    echo "$dest"
done
# host:1080
# host:22
# host:443
```

**Join an array into a comma-separated string:**

```bash
local arr=("host:1080" "host:22" "host:443")
local joined
joined=$(IFS=','; echo "${arr[*]}")
# host:1080,host:22,host:443
```

**Gotcha:** `IFS=','` in a subshell `$(...)` doesn't affect the parent. The `read` version sets IFS only for the `read` command. Both are safe — they don't change global IFS.

---

## 8. Heredoc Nesting Problems

**Problem:** Generating a file that itself generates a file.

```bash
# Script generates entrypoint.sh which generates startup.sh
# That's a heredoc writing a heredoc writing a heredoc

cat > entrypoint.sh << 'EEOF'
    cat > startup.sh << 'STARTUPEOF'    # This ends EEOF!
    ...
    STARTUPEOF
EEOF
```

The inner `STARTUPEOF` can confuse the outer heredoc. And if the inner heredoc content comes from a variable, quoting becomes a nightmare.

**Solution:** Use `echo` commands instead of nested heredocs:

```bash
cat > entrypoint.sh << 'EEOF'
    {
        echo "#!/bin/bash"
        echo "xfwm4 &"
        echo "xfdesktop &"
        echo "wait"
    } > startup.sh
EEOF
```

No nesting, no delimiter conflicts, no quoting levels to track.

---

## 9. Argument Parsing — Supporting Both Formats

**Problem:** Users expect both `--flag value` and `--flag=value`:

```bash
dev-sandbox --ssh-port 2228       # works
dev-sandbox --ssh-port=2228       # should also work
```

**Solution:** Handle `=` format in each case:

```bash
parse_opt_value() {
    local opt="$1"
    if [[ "$opt" == *=* ]]; then
        echo "${opt#*=}"
        return 0
    fi
    return 1
}

case "$1" in
    --ssh-port|--ssh-port=*)
        val=""
        if val=$(parse_opt_value "$1"); then shift
        elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
        else err "Missing port"; exit 1; fi
        SSH_PORT="$val"
        ;;
esac
```

**Gotcha:** `local` only works inside functions. If your parser is in global scope (like dev-sandbox), use `val=""` instead of `local val`.

---

## 10. `stat` for Conditional Operations

**Problem:** Only `chown` directories that actually need it (avoid unnecessary writes on every start).

```bash
# BAD — runs chown every time, even when unnecessary
chown dev:dev /home/dev/.claude

# GOOD — check first, act only if needed
if [[ "$(stat -c '%U' /home/dev/.claude)" != "dev" ]]; then
    chown dev:dev /home/dev/.claude
fi
```

**Useful `stat` formats:**

```bash
stat -c '%U' file    # Owner name (dev, root)
stat -c '%u' file    # Owner UID (1000, 0)
stat -c '%s' file    # Size in bytes
stat -c '%Y' file    # Modification time (epoch)
```

---

## 11. Color Output Without Complexity

**Setup once, use everywhere:**

```bash
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

info()  { echo -e "${CYAN}▶${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
```

**Note:** `$'...'` is ANSI-C quoting — processes escape sequences at assignment time, not at echo time. More reliable than `\e` or `\033` in echo.

---

## 12. Trap for Cleanup

```bash
cleanup() {
    sync 2>/dev/null || true
}
trap cleanup EXIT INT TERM
```

**EXIT** fires on normal exit, **INT** on Ctrl+C, **TERM** on `kill`. The `|| true` prevents the trap itself from failing under `set -e`.

**Gotcha with `exec`:** `exec` replaces the current process. If you `exec` another command, the trap fires at that point (before the new process starts), not when the new process exits.

---

## 13. Checking If a Variable Exists (Not Just Empty)

```bash
# ${!ref:-} returns empty for BOTH unset and empty
# Can't distinguish "not configured" from "set to empty string"

# Solution: ${!ref+x} — returns "x" if set (even if empty), nothing if unset
if [[ -n "${!ref+x}" ]]; then
    echo "Variable exists (might be empty)"
else
    echo "Variable not set at all"
fi
```

Used in the defaults system — profile variable set to empty string overrides default, but unset variable falls through to default:

```bash
get_profile_var() {
    local ref="PROFILE_${1}_${2}"
    if [[ -n "${!ref+x}" ]]; then
        echo "${!ref}"        # Profile value (even if empty)
    else
        local def="DEFAULT_${2}"
        echo "${!def:-}"      # Fall through to default
    fi
}
```

---

## 14. Glob Patterns and `.` / `..`

**Problem:** `/.*/` matches `.` and `..` — iterating hidden dirs can change parent directory ownership.

```bash
# BAD — includes . and ..
for d in /home/dev/.*/; do
    chown dev:dev "$d"           # Changes /home ownership!
done

# GOOD — skip . and ..
for d in /home/dev/.*/; do
    name=$(basename "$d")
    if [[ "$name" == "." ]] || [[ "$name" == ".." ]]; then
        continue
    fi
    chown dev:dev "$d"
done
```

---

## 15. Podman Wrapper Pattern

**Problem:** Every podman command needs the same global flags (custom storage path).

```bash
# Repetitive
podman --root /mnt/storage --storage-driver overlay build ...
podman --root /mnt/storage --storage-driver overlay run ...
podman --root /mnt/storage --storage-driver overlay images ...
```

**Solution:** Global array + wrapper function:

```bash
PODMAN_GLOBAL_FLAGS=()
if [[ -n "$PODMAN_STORAGE" ]]; then
    PODMAN_GLOBAL_FLAGS=(--root "$PODMAN_STORAGE" --storage-driver overlay)
fi

pcmd() {
    podman "${PODMAN_GLOBAL_FLAGS[@]}" "$@"
}

# Clean usage
pcmd build -t myimage .
pcmd run --rm -it myimage
pcmd images
```

**Gotcha (original bug):** The first version used `echo` + command substitution:

```bash
# BUG — word splitting breaks paths with spaces
podman_global_flags() { echo "--root $STORAGE"; }
flags=($(podman_global_flags))    # Word splits on spaces in path!
```

Global array avoids the echo→split round-trip entirely.

---

## 16. Profile Name Detection in Arguments

**Problem:** User types `dev-sandbox vncgui` instead of `dev-sandbox -p vncgui`.

```bash
case "${1:-}" in
    build|clean|status|ls|help) ... ;;
    *)
        # Is this a profile name?
        for p in "${ALL_PROFILES[@]}"; do
            if [[ "$p" == "$1" ]]; then
                err "Did you mean: dev-sandbox -p $1"
                exit 1
            fi
        done
        # Not a profile, not a command
        err "Unknown command: $1"
        exit 1
        ;;
esac
```

Small touch, saves confusion. User gets a helpful message instead of a cryptic container error.

---

---

## 17. Assembling Complex Podman Commands

The `podman run` call in dev-sandbox has ~15 conditional parts. Building it as a string would be unmaintainable. Instead, each concern gets its own array, and they're all combined at the end.

**The pattern:**

```bash
do_run() {
    # Each concern builds its own flags
    local krun_flags=()
    local net_flags=()
    local ssh_flags=()
    local cap_flags=()
    local env_flags=()
    local vol_flags=()
    local profile_args=()

    # Conditionally populate
    if [[ "$use_krun" == "true" ]]; then
        krun_flags+=(--annotation "run.oci.handler=krun")
        krun_flags+=(--annotation "krun.ram_mib=${ram}")
        krun_flags+=(--annotation "krun.cpus=${cpus}")
    else
        krun_flags+=(--memory "${ram}m")
        krun_flags+=(--cpus "${cpus}")
    fi

    if [[ "$ssh_port" != "0" ]]; then
        ssh_flags+=(-p "127.0.0.1:${ssh_port}:22")
        env_flags+=(-e "SANDBOX_SSHD=true")
    fi

    if [[ "$net_mode" == "locked" ]]; then
        env_flags+=(-e "SANDBOX_FIREWALL=locked")
        cap_flags+=(--cap-add NET_ADMIN)
    fi

    for vdir in "${volumes[@]}"; do
        vol_flags+=(-v "${profile}-sandbox-${vdir#.}:/home/dev/${vdir}")
    done

    # One clean podman call — all arrays expand in place
    podman run --rm -it \
        --name "${name}" \
        --hostname "${profile}-sandbox" \
        "${krun_flags[@]}" \
        "${net_flags[@]}" \
        "${ssh_flags[@]}" \
        "${cap_flags[@]}" \
        "${profile_args[@]}" \
        --security-opt label=disable \
        --userns keep-id \
        -v "${project}:${mount}" \
        -v "${vol_pip}:/home/dev/.local" \
        -v "${vol_root}:/etc/sandbox" \
        "${vol_flags[@]}" \
        -w "${mount}" \
        "${env_flags[@]}" \
        "${image}" \
        "$@"
}
```

**Why this works:** Empty arrays expand to nothing. If SSH is off, `"${ssh_flags[@]}"` vanishes — no empty string, no stray argument. The podman command sees exactly the flags that were added, nothing more.

**Real example — what podman actually receives for claude profile:**

```bash
podman run --rm -it \
    --name claude-myproject-a1b2c3 \
    --hostname claude-sandbox \
    --annotation run.oci.handler=krun \
    --annotation krun.ram_mib=4096 \
    --annotation krun.cpus=4 \
    -p 127.0.0.1:2228:22 \
    --tmpfs /var/log:rw,size=50m,mode=1777 \
    --tmpfs /tmp:rw,size=200m,mode=1777 \
    --security-opt label=disable \
    --userns keep-id \
    -v /home/tomaz/myproject:/app/myproject-a1b2c3 \
    -v claude-sandbox-pip:/home/dev/.local \
    -v claude-sandbox-rootconf:/etc/sandbox \
    -v claude-sandbox-claude:/home/dev/.claude \
    -v claude-sandbox-cache:/home/dev/.cache \
    -w /app/myproject-a1b2c3 \
    -e TERM=xterm-256color \
    -e COLORTERM=truecolor \
    -e SANDBOX_SUDO_HASH='$6$salt$hash...' \
    -e SANDBOX_SSHD=true \
    claude-sandbox-krun
```

15+ arguments, all conditional, all correct, no quoting issues.

---

## 18. Environment Variable Layering

Variables pass through four boundaries. Each needs explicit forwarding.

```
Host                    Container PID 1 (root)        dev user shell
─────────────────────  ──────────────────────────     ─────────────────
                        podman -e sets these:
DEV_SANDBOX_RAM=4096    SANDBOX_SSHD=true              (not inherited)
                        SANDBOX_SUDO_HASH=$6$...       (not inherited)
                        SANDBOX_FIREWALL=locked         (not inherited)
                        HTTP_PROXY=http://...           HTTP_PROXY=http://...
                        OLLAMA_HOST=http://...          OLLAMA_HOST=http://...
```

**Layer 1: Host → Container**
Podman `-e` passes env vars to PID 1 (root entrypoint):

```bash
env_flags+=(-e "SANDBOX_SSHD=true")
env_flags+=(-e "HTTP_PROXY=http://127.0.0.1:8118")

podman run "${env_flags[@]}" image
```

**Layer 2: Root entrypoint → Dev user**
`exec runuser -u dev -- env VAR=val` explicitly sets what dev sees. Variables NOT listed here are invisible to dev:

```bash
exec runuser -u "${U}" -- env \
    HOME="${HOME}" \
    PATH="${PATH}" \
    HTTP_PROXY="${HTTP_PROXY:-}" \
    ${EXTRA_ENV_ARGS} \
    "$@"
```

`SANDBOX_SUDO_HASH` is intentionally NOT forwarded — dev user never sees the password hash.

**Layer 3: Custom variables via EXTRA_ENV_ARGS**
Custom env vars from `--env` and profile `ENV`/`ENV_PASS` are forwarded dynamically:

```bash
# Host side (do_run): collect var names
extra_env_names+=("OLLAMA_HOST")
env_flags+=(-e "SANDBOX_EXTRA_ENV=OLLAMA_HOST")

# Container side (entrypoint): build passthrough
if [ -n "${SANDBOX_EXTRA_ENV:-}" ]; then
    IFS=',' read -ra _EVARS <<< "${SANDBOX_EXTRA_ENV}"
    for _evar in "${_EVARS[@]}"; do
        EXTRA_ENV_ARGS="${EXTRA_ENV_ARGS} ${_evar}=$(printenv ${_evar})"
    done
fi

# Passed to runuser
exec runuser ... ${EXTRA_ENV_ARGS} "$@"
```

**Why not just inherit everything?** Security. PID 1 sees `SANDBOX_SUDO_HASH`, `SANDBOX_FIREWALL`, and internal flags. Dev user should only see what's explicitly forwarded. The whitelist approach prevents accidental leaks.

---

## 19. Generating Dockerfiles from Config

**Problem:** Profile config is bash arrays and variables. Podman needs Dockerfiles on disk.

**Solution:** Scaffold functions generate files, `podman build` reads them:

```bash
generate_profile_dockerfile() {
    local profile="$1"
    local phome=$(profile_home "$profile")

    # Read arrays via indirect reference
    local ref="PROFILE_${profile}_DNF[@]"
    local extra_dnf=("${!ref}")

    # Build DNF line only if packages exist
    local dnf_line=""
    if [[ ${#extra_dnf[@]} -gt 0 ]] && [[ -n "${extra_dnf[0]:-}" ]]; then
        local pkgs=$(printf '%s ' "${extra_dnf[@]}")
        dnf_line="RUN dnf install -y ${pkgs} && dnf clean all"
    fi

    # Same for agents — skip commented lines
    local ref3="PROFILE_${profile}_AGENTS[@]"
    local agents=("${!ref3}")
    local agent_runs=""
    for agent in "${agents[@]}"; do
        local clean=$(echo "$agent" | sed 's/#.*//g' | tr '\n' ' ')
        if [ -n "$clean" ]; then
            agent_runs="${agent_runs}RUN ${clean}\n"
        fi
    done

    # Write Dockerfile
    cat > "${phome}/Dockerfile" << DEOF
FROM ${BASE_IMAGE_NAME}:latest
${dnf_line}
USER dev
${agent_runs}
USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
DEOF
}
```

**Key patterns:**
- `printf '%s '` joins array for DNF command line
- `sed 's/#.*//g'` strips comments (commented agents are skipped)
- Heredoc with `DEOF` (unquoted) — variables are expanded
- Empty `$dnf_line` results in a blank line, which is harmless

---

## 20. Embedding Config in Entrypoint via Heredoc

**Problem:** Profile defines startup scripts and wrappers as bash strings. These must end up inside the generated entrypoint.sh, which is itself generated via heredoc.

```bash
# Profile config (in script)
PROFILE_claude_ROOT_STARTUP='
if [ ! -f "$cfg" ]; then
    latest=$(ls -t "$backupdir"/*.backup.* | head -1)
    cp "$latest" "$cfg"
fi
'

PROFILE_claude_ROOT_WRAPPERS=(
    'claude|#!/bin/bash
exec "${HOME}/.claude/bin/claude" "$@"'
)
```

**How it flows:**

```
1. Script reads PROFILE_claude_ROOT_STARTUP → string in memory
2. String is assigned to startup_content variable
3. startup_content is embedded in entrypoint.sh heredoc:

   cat > entrypoint.sh << EEOF
   ...
   cat > /etc/sandbox/startup.sh << 'STARTUPEOF'
   ${startup_content}            ← expands here (EEOF is unquoted)
   STARTUPEOF                    ← inner heredoc is quoted (no expansion)
   ...
   EEOF
```

**Why `EEOF` unquoted but `STARTUPEOF` quoted?**
- `EEOF` (unquoted): We WANT variable expansion — `${startup_content}` must be replaced with actual content
- `'STARTUPEOF'` (quoted): We DON'T want expansion of `$cfg`, `$latest` etc — those are runtime variables for when startup.sh executes

**Wrapper generation — building shell code from shell code:**

```bash
local wrapper_init_block=""
for entry in "${wrappers[@]}"; do
    local wname="${entry%%|*}"
    local wbody="${entry#*|}"
    wrapper_init_block="${wrapper_init_block}
    if [ ! -f \"\${ROOTCONF}/wrappers/${wname}\" ]; then
        cat > \"\${ROOTCONF}/wrappers/${wname}\" << 'WRAPEOF'
${wbody}
WRAPEOF
    fi"
done
```

Note the escaping: `\"` because this code lives inside a double-quoted heredoc. `${wname}` and `${wbody}` expand at generation time (the right values). `\${ROOTCONF}` expands at runtime (inside the container).

**When heredocs fail — the VNC xstartup case:**

Three levels of quoting (script → entrypoint heredoc → startup string → xstartup heredoc) was one level too many. The `$()` in `eval $(dbus-launch)` got expanded at the wrong level. Solution: replace the innermost heredoc with echo commands:

```bash
# Instead of heredoc in heredoc in heredoc:
{
    echo "#!/bin/bash"
    echo "eval \$(dbus-launch --sh-syntax)"
    echo "xfwm4 &"
} > xstartup
```

---

## 21. First-Run-Only Pattern

**Problem:** Generate default config on first run, but never overwrite user edits.

```bash
# Startup hook
if [ ! -f "${ROOTCONF}/startup.sh" ]; then
    cat > "${ROOTCONF}/startup.sh" << 'EOF'
    # default content
EOF
    echo "▶ Generated startup.sh"
fi

# Wrappers
if [ ! -f "${ROOTCONF}/wrappers/claude" ]; then
    # generate
fi

# Dotfiles
if [ ! -f "${HOME}/.local/etc/bashrc.local" ]; then
    # generate
fi
```

**Same pattern everywhere:** Check if file exists → generate only if missing. User edits persist in volumes. Deleting the volume resets to defaults.

This creates a clear contract:
- First run: script generates defaults from config
- Next runs: uses whatever is in the volume
- Reset: `podman volume rm name` → next run regenerates

---

## Summary

| # | Trick | When to use |
|---|---|---|
| 1 | `${!ref}` | Dynamic variable names |
| 2 | `${!ref}` with `[@]` | Dynamic array names |
| 3 | `if/then` not `&&` | Under `set -e` |
| 4 | Empty array expansion | Optional podman flags |
| 5 | Parameter expansion | String splitting, defaults, tilde |
| 6 | Arrays for commands | Building complex CLI invocations |
| 7 | IFS split/join | CSV parsing, comma-joined strings |
| 8 | Echo not heredoc | Nested file generation |
| 9 | `--opt=val` parsing | User-friendly CLI |
| 10 | `stat -c '%U'` | Conditional ownership fix |
| 11 | `$'...'` colors | Consistent terminal output |
| 12 | `trap EXIT` | Cleanup on any exit |
| 13 | `${!ref+x}` | Distinguish unset from empty |
| 14 | Skip `.` `..` | Safe glob iteration |
| 15 | Wrapper + global array | DRY podman invocations |
| 16 | Profile name detection | Helpful error messages |
| 17 | Multi-array assembly | Complex podman commands |
| 18 | Env var layering | Controlled variable forwarding |
| 19 | Config → Dockerfile | Generating build files from arrays |
| 20 | Heredoc embedding | Config strings in generated scripts |
| 21 | First-run-only | Idempotent defaults with user edits |
