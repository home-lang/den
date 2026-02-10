#!/bin/bash
# Den Shell Integration Tests
# Tests den shell features using `den -c` against expected outputs.
#
# Usage:
#   ./tests/test_shell_features.sh              # Run all tests
#   DEN=/path/to/den ./tests/test_shell_features.sh  # Custom binary path

DEN="${DEN:-./zig-out/bin/den}"

# Verify den binary exists
if [ ! -x "$DEN" ]; then
    echo "Error: den binary not found at '$DEN'"
    echo "Build first: zig build -Doptimize=ReleaseSafe"
    exit 1
fi

PASS=0
FAIL=0
SKIP=0
FAILURES=""

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILURES="${FAILURES}FAIL: ${desc}\n  expected: '${expected}'\n  actual:   '${actual}'\n"
    fi
}

skip() {
    local desc="$1" reason="$2"
    SKIP=$((SKIP+1))
}

# ===========================================================================
# 1. Core features (echo, variables, substitution, arithmetic)
# ===========================================================================
check "echo" "hello" "$(timeout 3 $DEN -c 'echo hello')"
check "variable" "world" "$(timeout 3 $DEN -c 'x=world; echo $x')"
check "cmd subst" "inner" "$(timeout 3 $DEN -c 'echo $(echo inner)')"
check "assign subst" "val" "$(timeout 3 $DEN -c 'x=$(echo val); echo $x')"
check "arithmetic add" "8" "$(timeout 3 $DEN -c 'echo $((3+5))')"
check "arithmetic mult" "12" "$(timeout 3 $DEN -c 'echo $((3*4))')"
check "arithmetic mod" "1" "$(timeout 3 $DEN -c 'echo $((7%3))')"
check "arithmetic parens" "14" "$(timeout 3 $DEN -c 'echo $(( (2 + 5) * 2 ))')"
check "arithmetic vars" "15" "$(timeout 3 $DEN -c 'x=10; y=5; echo $((x+y))')"
check "arithmetic negate" "-5" "$(timeout 3 $DEN -c 'echo $(( -5 ))')"
check "arithmetic shift" "8" "$(timeout 3 $DEN -c 'echo $(( 1 << 3 ))')"
check "arithmetic ternary" "1" "$(timeout 3 $DEN -c 'echo $(( 5 > 3 ? 1 : 0 ))')"
check "exit code" "1" "$(timeout 3 $DEN -c 'false; echo $?')"
check "env var" "bar" "$(FOO=bar timeout 3 $DEN -c 'echo $FOO')"
check "quoted assign" "hello world" "$(timeout 3 $DEN -c 'x="hello world"; echo $x')"
check "backtick" "backtick" "$(timeout 3 $DEN -c 'echo `echo backtick`')"
check "nested subst" "INNER" "$(timeout 3 $DEN -c 'echo $(echo $(echo INNER))')"

# ===========================================================================
# 2. Pipes and redirects
# ===========================================================================
check "pipe" "3" "$(timeout 3 $DEN -c 'echo -e "a\nb\nc" | wc -l | tr -d " "')"
check "redirect output" "redir_ok" "$(timeout 3 $DEN -c 'echo redir_ok > /tmp/den_redir.txt; cat /tmp/den_redir.txt'; rm -f /tmp/den_redir.txt)"
check "redirect append" "line2" "$(timeout 3 $DEN -c 'echo line1 > /tmp/den_app.txt; echo line2 >> /tmp/den_app.txt; tail -1 /tmp/den_app.txt'; rm -f /tmp/den_app.txt)"
check "redirect input" "hello" "$(echo hello > /tmp/den_in.txt; timeout 3 $DEN -c 'cat < /tmp/den_in.txt'; rm -f /tmp/den_in.txt)"
check "stderr redirect" "" "$(timeout 3 $DEN -c 'echo error >&2' 2>/dev/null)"
check "cmd -v redirect" "found" "$(timeout 3 $DEN -c 'if command -v echo > /dev/null 2>&1; then echo found; fi')"
check "pipe in cmd subst" "3" "$(timeout 3 $DEN -c 'echo $(echo "a b c" | wc -w | tr -d " ")')"
check "tr -d space in subst" "abc" "$(timeout 3 $DEN -c 'echo $(echo " abc " | tr -d " ")')"
check "here string" "hello" "$(timeout 3 $DEN -c 'cat <<< hello')"

# ===========================================================================
# 3. Conditional operators
# ===========================================================================
check "conditional &&" "yes" "$(timeout 3 $DEN -c 'true && echo yes')"
check "conditional ||" "fallback" "$(timeout 3 $DEN -c 'false || echo fallback')"
check "chain && ||" "recovered" "$(timeout 3 $DEN -c 'true && false || echo recovered')"
check "true exit" "0" "$(timeout 3 $DEN -c 'true; echo $?')"
check "false exit" "1" "$(timeout 3 $DEN -c 'false; echo $?')"

# ===========================================================================
# 4. Control flow: if/elif/else/fi
# ===========================================================================
check "if/else" "else_branch" "$(timeout 3 $DEN -c 'if false; then echo then_branch; else echo else_branch; fi')"
check "elif" "two" "$(timeout 5 $DEN -c 'x=2; if [ "$x" = "1" ]; then echo one; elif [ "$x" = "2" ]; then echo two; fi')"
check "nested if" "RIGHT" "$(timeout 3 $DEN -c 'if true; then if false; then echo WRONG; else echo RIGHT; fi; fi')"
check "complex elif" "medium" "$(timeout 5 $DEN -c 'x=5; if [ $x -gt 10 ]; then echo big; elif [ $x -gt 3 ]; then echo medium; else echo small; fi')"

# ===========================================================================
# 5. Loops: for, while, until
# ===========================================================================
check "for loop" "1 2 3" "$(timeout 3 $DEN -c 'for i in 1 2 3; do echo $i; done' | tr '\n' ' ' | sed 's/ $//')"
check "while loop" "3" "$(timeout 3 $DEN -c 'i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i')"
check "for break" "1 2" "$(timeout 3 $DEN -c 'for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then break; fi; echo $i; done' | tr '\n' ' ' | sed 's/ $//')"
check "for continue" "1 2 4 5" "$(timeout 3 $DEN -c 'for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then continue; fi; echo $i; done' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 6. Case statements
# ===========================================================================
check "case match" "matched_b" "$(timeout 3 $DEN -c 'case b in a) echo matched_a;; b) echo matched_b;; esac')"
check "case wildcard" "other" "$(timeout 3 $DEN -c 'x=hello; case $x in foo) echo foo;; *) echo other;; esac')"

# ===========================================================================
# 7. Test builtins: [ ], [[ ]], test
# ===========================================================================
check "test -f" "exists" "$(timeout 3 $DEN -c 'test -f /etc/hosts && echo exists')"
check "test -z" "empty" "$(timeout 3 $DEN -c 'x=""; if [ -z "$x" ]; then echo empty; fi')"
check "test -n" "notempty" "$(timeout 3 $DEN -c 'x=hi; if [ -n "$x" ]; then echo notempty; fi')"
check "string eq" "equal" "$(timeout 3 $DEN -c 'if [ "abc" = "abc" ]; then echo equal; fi')"
check "numeric gt" "yes" "$(timeout 3 $DEN -c 'if [ 5 -gt 3 ]; then echo yes; fi')"
check "[[ glob ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" == a* ]] && echo yes')"
check "[[ regex ]]" "yes" "$(timeout 3 $DEN -c '[[ "hello123" =~ [0-9]+ ]] && echo yes')"
check "[[ != ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" != x* ]] && echo yes')"
check "[[ anchored ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" =~ ^[a-z]+$ ]] && echo yes')"

# ===========================================================================
# 8. Functions
# ===========================================================================
check "func basic" "hello world" "$(timeout 3 $DEN -c 'greet() { echo "$1 $2"; }; greet hello world')"
check "func for" "a b" "$(timeout 5 $DEN -c 'myfn() { for x in a b; do echo $x; done; }; myfn' | tr '\n' ' ' | sed 's/ $//')"
check "func args \$@" "a b c" "$(timeout 5 $DEN -c 'showargs() { for arg in "$@"; do echo $arg; done; }; showargs a b c' | tr '\n' ' ' | sed 's/ $//')"
check "return value" "42" "$(timeout 3 $DEN -c 'retfn() { return 42; }; retfn; echo $?')"
check "func if" "yes" "$(timeout 3 $DEN -c 'checkfn() { if true; then echo yes; else echo no; fi; }; checkfn')"
check "func while local" "3" "$(timeout 5 $DEN -c 'countfn() { local i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i; }; countfn')"
check "nested func" "inner" "$(timeout 3 $DEN -c 'outer() { inner() { echo inner; }; inner; }; outer')"

# ===========================================================================
# 9. Local variables
# ===========================================================================
check "local update" "1" "$(timeout 3 $DEN -c 'f() { local x=0; x=1; echo $x; }; f')"
check "local scope" "global" "$(timeout 3 $DEN -c 'x=global; f() { local x=local; x=changed; }; f; echo $x')"
check "local arith" "2" "$(timeout 3 $DEN -c 'f() { local i=0; i=1; echo $((i+1)); }; f')"

# ===========================================================================
# 10. Parameter expansion
# ===========================================================================
check "param default" "default" "$(timeout 3 $DEN -c 'echo ${UNSET_VAR:-default}')"
check "param assign" "default" "$(timeout 3 $DEN -c 'echo ${UNSET_VAR:=default}')"
check "param length" "5" "$(timeout 3 $DEN -c 'x=hello; echo ${#x}')"
check "## strip" "file.txt" "$(timeout 3 $DEN -c 'x=/path/to/file.txt; echo ${x##*/}')"
check "% strip" "/path/to" "$(timeout 3 $DEN -c 'x=/path/to/file.txt; echo ${x%/*}')"
check "/ replace" "hello_world" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x/ /_}')"
check "// replace all" "hell- w-rld" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x//o/-}')"
check "substring" "llo" "$(timeout 3 $DEN -c 'x=hello; echo ${x:2}')"
check "substring len" "el" "$(timeout 3 $DEN -c 'x=hello; echo ${x:1:2}')"

# ===========================================================================
# 11. Subshells and misc
# ===========================================================================
check "subshell" "sub" "$(timeout 3 $DEN -c '(echo sub)')"
check "subshell semi" "a b" "$(timeout 3 $DEN -c '(echo a; echo b)' | tr '\n' ' ' | sed 's/ $//')"
check "command -v" "echo" "$(timeout 3 $DEN -c 'command -v echo')"
check "cd+pwd" "/private/tmp" "$(timeout 3 $DEN -c 'cd /tmp; pwd')"
check "tilde expand" "$HOME" "$(timeout 3 $DEN -c 'echo ~')"

# ===========================================================================
# 12. Variable operations
# ===========================================================================
check "export var" "exported" "$(timeout 3 $DEN -c 'export MY_VAR=exported; echo $MY_VAR')"
check "unset var" "" "$(timeout 3 $DEN -c 'x=hello; unset x; echo -n $x')"
check "+= append" "helloworld" "$(timeout 3 $DEN -c 'x=hello; x+=world; echo $x')"

# ===========================================================================
# 13. Quoting and escaping
# ===========================================================================
check "backslash dollar" '$HOME' "$(timeout 3 $DEN -c 'echo \$HOME')"

# ===========================================================================
# 14. Trap and set
# ===========================================================================
check "trap EXIT" "main cleanup" "$(timeout 3 $DEN -c 'trap "echo cleanup" EXIT; echo main' | tr '\n' ' ' | sed 's/ $//')"
check "set -e" "before" "$(timeout 3 $DEN -c 'set -e; echo before; false; echo after')"

# ===========================================================================
# 15. Exit code propagation
# ===========================================================================
$DEN -c 'exit 1' 2>/dev/null; check "exit 1" "1" "$?"
$DEN -c 'exit 42' 2>/dev/null; check "exit 42" "42" "$?"

# ===========================================================================
# 16. Negation
# ===========================================================================
check "negation standalone" "1" "$(timeout 3 $DEN -c '! true; echo $?' 2>/dev/null)"

# ===========================================================================
# 17. Trailing semicolons
# ===========================================================================
check "trailing semicolon" "ok" "$(timeout 3 $DEN -c 'echo ok;')"

# ===========================================================================
# 18. Printf
# ===========================================================================
check "printf fmt" "num: 42" "$(timeout 3 $DEN -c 'printf "num: %d\n" 42')"

# ===========================================================================
# 19. Read builtin
# ===========================================================================
check "read single" "hello world" "$(echo "hello world" | timeout 3 $DEN -c 'read x; echo $x')"
check "read multi" "hello world" "$(echo "hello world" | timeout 3 $DEN -c 'read x y; echo "$x $y"')"

# ===========================================================================
# 20. Multiple pipes
# ===========================================================================
check "multiple pipes" "3" "$(timeout 3 $DEN -c 'echo -e "aa\nbb\ncc" | /usr/bin/wc -l | tr -d " "')"

# ===========================================================================
# 21. Misc: source, let, heredoc, multi-assign
# ===========================================================================
check "let builtin" "10" "$(timeout 3 $DEN -c 'let x=5+5; echo $x')"
check "multi assign" "2" "$(timeout 3 $DEN -c 'a=1; b=2; echo $b')"
check "multi cmd subst" "hello world" "$(timeout 3 $DEN -c 'a=$(echo hello); b=$(echo world); echo "$a $b"')"
check "empty if body" "" "$(timeout 3 $DEN -c 'if false; then echo wrong; fi' 2>/dev/null)"
check "heredoc basic" "hello" "$(timeout 3 $DEN -c 'cat << EOF
hello
EOF')"
check "source" "sourced" "$(echo 'echo sourced' > /tmp/den_source_test.sh; timeout 3 $DEN -c 'source /tmp/den_source_test.sh'; rm -f /tmp/den_source_test.sh)"
check "dot source" "dotted" "$(echo 'echo dotted' > /tmp/den_dot_test.sh; timeout 3 $DEN -c '. /tmp/den_dot_test.sh'; rm -f /tmp/den_dot_test.sh)"

# ===========================================================================
# 22. Real-world patterns (Claude Code, scripts)
# ===========================================================================
check "tool check pattern" "found" "$(timeout 3 $DEN -c 'if command -v echo > /dev/null 2>&1; then echo found; else echo missing; fi')"
check "var as cmd" "hello" "$(timeout 3 $DEN -c 'cmd=echo; $cmd hello')"
check "stderr suppression" "ok" "$(timeout 3 $DEN -c 'ls /nonexistent 2>/dev/null; echo ok')"
check "set +e" "after" "$(timeout 3 $DEN -c 'set -e; set +e; false; echo after')"
check "exported to subprocess" "hello" "$(timeout 3 $DEN -c 'export X=hello; echo $X')"
check "func return check" "success" "$(timeout 3 $DEN -c 'check() { return 0; }; if check; then echo success; fi')"
check "assign from pipe" "hello" "$(timeout 3 $DEN -c 'x=$(echo hello | cat); echo $x')"
check "string concat" "ab" "$(timeout 3 $DEN -c 'a=a; b=b; echo "$a$b"')"
check "env passthrough" "test_val" "$(TEST_ENV=test_val timeout 3 $DEN -c 'echo $TEST_ENV')"
check "three pipes" "1" "$(timeout 3 $DEN -c 'echo "hello" | wc -l | tr -d " "')"

# ===========================================================================
# 23. Arrays
# ===========================================================================
check "array assign" "b" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[1]}')"
check "array all" "a b c" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[@]}')"
check "array length" "3" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${#arr[@]}')"
check "array append" "a b c d" "$(timeout 3 $DEN -c 'arr=(a b c); arr+=(d); echo ${arr[@]}')"

# ===========================================================================
# 24. Case conversion
# ===========================================================================
check "uppercase all" "HELLO" "$(timeout 3 $DEN -c 'x=hello; echo ${x^^}')"
check "lowercase all" "hello" "$(timeout 3 $DEN -c 'x=HELLO; echo ${x,,}')"
check "uppercase first" "Hello" "$(timeout 3 $DEN -c 'x=hello; echo ${x^}')"

# ===========================================================================
# 25. Arithmetic command (( ))
# ===========================================================================
check "(( assignment ))" "10" "$(timeout 3 $DEN -c 'x=5; (( x = x * 2 )); echo $x')"
check "(( condition ))" "0" "$(timeout 3 $DEN -c '(( 5 > 3 )); echo $?')"

# ===========================================================================
# 26. Backslash continuation
# ===========================================================================
check "backslash cont" "hello world" "$(timeout 3 $DEN -c $'echo hello \\\nworld')"

# ===========================================================================
# 27. Test builtin negation
# ===========================================================================
check "[ ! -f ] neg" "yes" "$(timeout 3 $DEN -c '[ ! -f /nonexistent ] && echo yes || echo no')"
check "[ ! -d ] neg" "no" "$(timeout 3 $DEN -c '[ ! -d /tmp ] && echo yes || echo no')"
check "[ ! = ] neg" "yes" "$(timeout 3 $DEN -c '[ ! "a" = "b" ] && echo yes || echo no')"

# ===========================================================================
# 28. Arithmetic post-increment/decrement
# ===========================================================================
check "(( x++ ))" "6" "$(timeout 3 $DEN -c 'x=5; (( x++ )); echo $x')"
check "(( x-- ))" "4" "$(timeout 3 $DEN -c 'x=5; (( x-- )); echo $x')"
check "(( ++x ))" "6" "$(timeout 3 $DEN -c 'x=5; (( ++x )); echo $x')"
check "(( --x ))" "4" "$(timeout 3 $DEN -c 'x=5; (( --x )); echo $x')"

# ===========================================================================
# 29. Readonly error code
# ===========================================================================
check "readonly err" "1" "$(timeout 3 $DEN -c 'readonly x=5; x=10; echo $?' 2>/dev/null)"

# ===========================================================================
# 30. Getopts
# ===========================================================================
check "getopts basic" "0" "$(timeout 3 $DEN -c 'getopts "ab:" opt -a; echo $?' 2>/dev/null)"

# ===========================================================================
# 31. Compound command groups
# ===========================================================================
check "{ compound }" "hello" "$(timeout 3 $DEN -c '{ echo hello; }')"
check "{ multi cmds }" "a
b" "$(timeout 3 $DEN -c '{ echo a; echo b; }')"

# ===========================================================================
# 32. Special variables
# ===========================================================================
R=$(timeout 3 $DEN -c 'echo $RANDOM' 2>/dev/null)
if [ -n "$R" ]; then check "RANDOM" "nonempty" "nonempty"; else check "RANDOM" "nonempty" ""; fi
check "LINENO" "1" "$(timeout 3 $DEN -c 'echo $LINENO' 2>/dev/null)"

# ===========================================================================
# 33. Test -s operator
# ===========================================================================
check "[ -s file ]" "yes" "$(timeout 3 $DEN -c '[ -s /etc/hosts ] && echo yes || echo no')"
check "[ -s empty ]" "no" "$(timeout 3 $DEN -c '[ -s /dev/null ] && echo yes || echo no')"

# ===========================================================================
# 34. Pipe to control flow (while read)
# ===========================================================================
check "pipe | while read" "a
b
c" "$(timeout 5 $DEN -c 'printf "a\nb\nc\n" | while read line; do echo $line; done')"
check "read EOF exit" "1" "$(printf "" | timeout 3 $DEN -c 'read x; echo $?')"

# ===========================================================================
# 35. Printf repeat pattern
# ===========================================================================
check "printf repeat" "a
b
c" "$(timeout 3 $DEN -c 'printf "%s\n" a b c')"
check "printf repeat int" "1 2 3" "$(timeout 3 $DEN -c 'printf "%d " 1 2 3' | sed 's/ $//')"

# ===========================================================================
# 36. Shift in functions
# ===========================================================================
check "shift in func" "x y" "$(timeout 3 $DEN -c 'f() { echo $1; shift; echo $1; }; f x y' | tr '\n' ' ' | sed 's/ $//')"
check "shift 2 in func" "c" "$(timeout 3 $DEN -c 'f() { shift 2; echo $1; }; f a b c')"

# ===========================================================================
# 37. Negative substring extraction
# ===========================================================================
check "substr negative" "lo" "$(timeout 3 $DEN -c 'x=hello; echo ${x:(-2)}')"
check "substr neg:len" "l" "$(timeout 3 $DEN -c 'x=hello; echo ${x:(-2):1}')"

# ===========================================================================
# 38. Array element assignment
# ===========================================================================
check "arr elem assign" "world" "$(timeout 3 $DEN -c 'arr=(a b c); arr[1]=world; echo ${arr[1]}')"
check "arr elem extend" "d" "$(timeout 3 $DEN -c 'arr=(a b c); arr[3]=d; echo ${arr[3]}')"

# ===========================================================================
# 39. Test string comparison
# ===========================================================================
check "test str <" "yes" "$(timeout 3 $DEN -c '[ "abc" \< "def" ] && echo yes || echo no')"
check "test str >" "yes" "$(timeout 3 $DEN -c '[ "def" \> "abc" ] && echo yes || echo no')"

# ===========================================================================
# 40. set -- positional parameters
# ===========================================================================
check "set --" "b" "$(timeout 3 $DEN -c 'set -- a b c; echo $2')"
check "set -- count" "3" "$(timeout 3 $DEN -c 'set -- x y z; echo $#')"

# ===========================================================================
# 41. set -u (nounset)
# ===========================================================================
check "set -u unbound" "den: UNDEFINED_VAR_12345: unbound variable" "$(timeout 3 $DEN -c 'set -u; echo $UNDEFINED_VAR_12345' 2>&1)"

# ===========================================================================
# 42. trap ERR
# ===========================================================================
check "trap ERR" "TRAPPED
after" "$(timeout 3 $DEN -c 'trap "echo TRAPPED" ERR; false; echo after' 2>&1)"

# ===========================================================================
# 43. declare -a inline array
# ===========================================================================
check "declare -a" "y" "$(timeout 3 $DEN -c 'declare -a arr=(x y z); echo ${arr[1]}')"
check "declare -a all" "hello world" "$(timeout 3 $DEN -c 'declare -a arr=(hello world); echo ${arr[@]}')"

# ===========================================================================
# 44. declare -i integer attribute
# ===========================================================================
check "declare -i +=" "8" "$(timeout 3 $DEN -c 'declare -i x=5; x+=3; echo $x')"
check "declare -i expr" "10" "$(timeout 3 $DEN -c 'declare -i x=5+5; echo $x')"

# ===========================================================================
# 45. declare -A associative arrays
# ===========================================================================
check "declare -A inline" "val1" "$(timeout 3 $DEN -c 'declare -A m=([key1]=val1 [key2]=val2); echo ${m[key1]}')"
check "declare -A subscript" "bar" "$(timeout 3 $DEN -c 'declare -A m; m[foo]=bar; echo ${m[foo]}')"

# ===========================================================================
# 46. printf -v
# ===========================================================================
check "printf -v" "num: 42" "$(timeout 3 $DEN -c 'printf -v result "num: %d" 42; echo $result')"

# ===========================================================================
# 47. Array slicing
# ===========================================================================
check "arr slice" "b c" "$(timeout 3 $DEN -c 'arr=(a b c d); echo ${arr[@]:1:2}')"

# ===========================================================================
# 48. Command substitution in for loop
# ===========================================================================
check "for cmd subst" "a b c" "$(timeout 3 $DEN -c 'for i in $(echo a b c); do echo $i; done' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 49. IFS in read
# ===========================================================================
check "IFS read" "a b c" "$(echo "a:b:c" | timeout 3 $DEN -c 'IFS=:; read x y z; echo "$x $y $z"')"
check "read -r" "hello" "$(echo "hello" | timeout 3 $DEN -c 'read -r x; echo $x')"

# ===========================================================================
# 50. Heredoc tab strip
# ===========================================================================
check "heredoc <<-" "hello" "$(timeout 3 $DEN -c $'cat <<-EOF\n\thello\nEOF')"

# ===========================================================================
# 51. PIPESTATUS
# ===========================================================================
check "PIPESTATUS" "0 1 0" "$(timeout 3 $DEN -c 'true | false | true; echo ${PIPESTATUS[@]}')"
check "PIPESTATUS idx" "1" "$(timeout 3 $DEN -c 'true | false | true; echo ${PIPESTATUS[1]}')"

# ===========================================================================
# 52. Herestring with read
# ===========================================================================
check "read herestring" "hello" "$(timeout 3 $DEN -c 'read x <<< "hello"; echo $x')"
check "read -a herestring" "y" "$(timeout 3 $DEN -c 'read -a arr <<< "x y z"; echo ${arr[1]}')"

# ===========================================================================
# 53. Array indices
# ===========================================================================
check "arr indices" "0 1 2" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${!arr[@]}')"

# ===========================================================================
# 54. Arithmetic comma operator
# ===========================================================================
check "arith comma" "7" "$(timeout 3 $DEN -c 'echo $(( 1+2, 3+4 ))')"

# ===========================================================================
# 55. Multi-line -c (control flow)
# ===========================================================================
check "multiline if" "yes" "$(timeout 3 $DEN -c $'if true\nthen\necho yes\nfi')"
check "multiline for" "a b c" "$(timeout 3 $DEN -c $'for i in a b c\ndo\necho $i\ndone' | tr '\n' ' ' | sed 's/ $//')"
check "multiline while" "3" "$(timeout 3 $DEN -c $'i=0\nwhile [ $i -lt 3 ]\ndo\ni=$((i+1))\ndone\necho $i')"

# ===========================================================================
# 56. FUNCNAME variable
# ===========================================================================
check "FUNCNAME" "myfunc" "$(timeout 3 $DEN -c 'myfunc() { echo $FUNCNAME; }; myfunc')"

# ===========================================================================
# 57. Arithmetic compound assignment operators
# ===========================================================================
check "(( x += ))" "15" "$(timeout 3 $DEN -c 'x=10; (( x += 5 )); echo $x')"
check "(( x -= ))" "7" "$(timeout 3 $DEN -c 'x=10; (( x -= 3 )); echo $x')"
check "(( x *= ))" "20" "$(timeout 3 $DEN -c 'x=10; (( x *= 2 )); echo $x')"
check "(( x /= ))" "3" "$(timeout 3 $DEN -c 'x=10; (( x /= 3 )); echo $x')"

# ===========================================================================
# 58. Local array in function
# ===========================================================================
check "local arr in func" "1 2 3" "$(timeout 3 $DEN -c 'f() { local arr=(1 2 3); echo ${arr[@]}; }; f')"
check "func body with \${}" "a b c" "$(timeout 3 $DEN -c 'f() { x=(a b c); echo ${x[@]}; }; f')"

# ===========================================================================
# 59. Multiline function definition via -c
# ===========================================================================
check "multiline func" "hi world" "$(timeout 3 $DEN -c $'greet() {\necho "hi $1"\n}\ngreet world')"

# ===========================================================================
# 60. Assoc array keys
# ===========================================================================
# Assoc array key count (order may vary, just check count)
ASSOC_KEYS=$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); echo ${!m[@]}' | wc -w | tr -d " ")
check "assoc keys count" "2" "$ASSOC_KEYS"

# ===========================================================================
# 61. Arithmetic with parameter expansion
# ===========================================================================
check "arith \${#x}" "4" "$(timeout 3 $DEN -c 'x=abc; echo $(( ${#x} + 1 ))')"
check "arith \${x}" "15" "$(timeout 3 $DEN -c 'x=10; echo $(( ${x} + 5 ))')"

# ===========================================================================
# 62. Case with pipe pattern
# ===========================================================================
check "case pipe pattern" "matched" "$(timeout 3 $DEN -c 'x=b; case $x in a|b|c) echo matched;; esac')"

# ===========================================================================
# 63. Indirect variable expansion
# ===========================================================================
check "indirect var" "hello" "$(timeout 3 $DEN -c 'x=hello; ref=x; echo ${!ref}')"

# ===========================================================================
# 64. Nested func calls
# ===========================================================================
check "nested func call" "a
b" "$(timeout 3 $DEN -c 'a() { echo a; }; b() { a; echo b; }; b')"

# ===========================================================================
# 65. Subshell variable isolation
# ===========================================================================
check "subshell var" "inner outer" "$(timeout 3 $DEN -c 'x=outer; (x=inner; echo $x); echo $x' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 66. Heredoc with quoted delimiter (no expansion)
# ===========================================================================
check "heredoc quoted" 'hello $x' "$(timeout 3 $DEN -c 'x=world; cat << "EOF"
hello $x
EOF')"

# ===========================================================================
# 67. Parameter error ${:?}
# ===========================================================================
check "param error" "den: x: not set" "$(timeout 3 $DEN -c 'echo ${x:?not set}' 2>&1 | head -1)"

# ===========================================================================
# 68. Until loop
# ===========================================================================
check "until loop" "3" "$(timeout 3 $DEN -c 'i=0; until [ $i -ge 3 ]; do i=$((i+1)); done; echo $i')"

# ===========================================================================
# 69. Multi-line case via -c
# ===========================================================================
check "multiline case" "matched" "$(timeout 3 $DEN -c $'x=hello\ncase $x in\nhello) echo matched;;\n*) echo nope;;\nesac')"

# ===========================================================================
# 70. String repeat with printf
# ===========================================================================
check "printf repeat str" "-----" "$(timeout 3 $DEN -c 'printf "%.0s-" 1 2 3 4 5')"

# ===========================================================================
# 71. Parameter substitution remove
# ===========================================================================
check "param remove" "hello " "$(timeout 3 $DEN -c 'x="hello world"; echo ${x/world}')"

# ===========================================================================
# 72. Conditional arithmetic
# ===========================================================================
check "if (( ))" "big" "$(timeout 3 $DEN -c 'x=5; if (( x > 3 )); then echo big; fi')"
check "while (( ))" "3" "$(timeout 3 $DEN -c 'i=0; while (( i < 3 )); do (( i++ )); done; echo $i')"

# ===========================================================================
# 73. Herestring with variable expansion
# ===========================================================================
check "herestring var" "hello world" "$(timeout 3 $DEN -c 'x=hello; read y <<< "$x world"; echo $y')"

# ===========================================================================
# 74. Export from function
# ===========================================================================
check "export in func" "123" "$(timeout 3 $DEN -c 'f() { export X=123; }; f; echo $X')"

# ===========================================================================
# 75. Read multiple lines from pipe
# ===========================================================================
check "read multi line" "line1 line2" "$(printf "line1\nline2\n" | timeout 3 $DEN -c 'read a; read b; echo "$a $b"')"

# ===========================================================================
# 76. Multiple assignment on one line
# ===========================================================================
check "multi assign" "1 2 3" "$(timeout 3 $DEN -c 'a=1 b=2 c=3; echo "$a $b $c"')"

# ===========================================================================
# 77. declare -l/-u on reassignment
# ===========================================================================
check "declare -l reassign" "hello" "$(timeout 3 $DEN -c 'declare -l x; x=HELLO; echo $x')"
check "declare -u reassign" "HELLO" "$(timeout 3 $DEN -c 'declare -u x; x=hello; echo $x')"

# ===========================================================================
# 78. unset array element
# ===========================================================================
check "unset arr elem" "a c" "$(timeout 3 $DEN -c 'arr=(a b c); unset arr[1]; echo ${arr[@]}')"
check "unset arr elem len" "2" "$(timeout 3 $DEN -c 'arr=(a b c); unset arr[1]; echo ${#arr[@]}')"

# ===========================================================================
# 79. For loop with brace expansion
# ===========================================================================
check "for brace sum" "15" "$(timeout 3 $DEN -c 'sum=0; for i in {1..5}; do sum=$((sum + i)); done; echo $sum')"
check "for brace persist" "END" "$(timeout 3 $DEN -c 'for i in {1..3}; do x=$i; done; echo END')"

# ===========================================================================
# 80. Array access in arithmetic
# ===========================================================================
check "arith arr access" "50" "$(timeout 3 $DEN -c 'arr=(10 20 30); echo $(( arr[1] + arr[2] ))')"
check "arith arr single" "20" "$(timeout 3 $DEN -c 'arr=(10 20 30); echo $(( arr[1] ))')"

# ===========================================================================
# 81. Variable array index
# ===========================================================================
check "var arr index" "20" "$(timeout 3 $DEN -c 'arr=(10 20 30); i=1; echo ${arr[$i]}')"

# ===========================================================================
# 82. declare -p
# ===========================================================================
check "declare -p" 'declare -- x="hello"' "$(timeout 3 $DEN -c 'x=hello; declare -p x')"
check "declare -p int" 'declare -i x="5"' "$(timeout 3 $DEN -c 'declare -i x=5; declare -p x')"

# ===========================================================================
# 83. SECONDS variable
# ===========================================================================
S=$(timeout 3 $DEN -c 'echo $SECONDS' 2>/dev/null)
if [ -n "$S" ]; then check "SECONDS" "nonempty" "nonempty"; else check "SECONDS" "nonempty" ""; fi

# ===========================================================================
# 84. read -n (nchars)
# ===========================================================================
check "read -n" "hel" "$(echo hello | timeout 3 $DEN -c 'read -n 3 x; echo $x')"

# ===========================================================================
# 85. read -d (delimiter)
# ===========================================================================
check "read -d" "hello" "$(echo 'hello|world' | timeout 3 $DEN -c 'read -d "|" x; echo $x')"

# ===========================================================================
# 86. ${var-default} without colon
# ===========================================================================
check "param default nocolon unset" "default" "$(timeout 3 $DEN -c 'echo ${undefined_var_test-default}')"
check "param default nocolon empty" "" "$(timeout 3 $DEN -c 'x=""; echo ${x-default}')"
check "param default nocolon set" "hello" "$(timeout 3 $DEN -c 'x=hello; echo ${x-default}')"

# ===========================================================================
# 87. ${var+word} without colon
# ===========================================================================
check "param plus set" "yes" "$(timeout 3 $DEN -c 'x=hello; echo ${x+yes}')"
check "param plus empty" "yes" "$(timeout 3 $DEN -c 'x=""; echo "${x+yes}"')"
check "param plus unset" "" "$(timeout 3 $DEN -c 'echo ${undefined_var_test2+yes}')"

# ===========================================================================
# 88. For C-style loop
# ===========================================================================
check "c-style for" "0 1 2" "$(timeout 3 $DEN -c 'for ((i=0; i<3; i++)); do echo $i; done' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 89. Arithmetic power operator
# ===========================================================================
check "arith power" "256" "$(timeout 3 $DEN -c 'echo $(( 2 ** 8 ))')"

# ===========================================================================
# 90. printf formatting
# ===========================================================================
check "printf %02d" "05" "$(timeout 3 $DEN -c 'printf "%02d\n" 5')"
check "printf %s" "hello" "$(timeout 3 $DEN -c 'printf "%s\n" hello')"

# ===========================================================================
# 91. test -e operator
# ===========================================================================
check "test -e" "yes" "$(timeout 3 $DEN -c '[ -e /tmp ] && echo yes')"

# ===========================================================================
# 92. Process substitution
# ===========================================================================
check "proc subst" "0" "$(timeout 3 $DEN -c 'diff <(echo a) <(echo a); echo $?')"

# ===========================================================================
# 93. Declare -x export
# ===========================================================================
check "declare -x" "exported" "$(timeout 3 $DEN -c 'declare -x MY_VAR=exported; echo $MY_VAR')"

# ===========================================================================
# 94. ${!prefix*} variable name expansion
# ===========================================================================
PCOUNT=$(timeout 3 $DEN -c 'FOO_A=1; FOO_B=2; echo ${!FOO*}' | wc -w | tr -d " ")
check "prefix match count" "2" "$PCOUNT"

# ===========================================================================
# 95. [[ -v variable ]] test
# ===========================================================================
check "[[ -v ]] set" "set" "$(timeout 3 $DEN -c 'x=hello; [[ -v x ]] && echo set || echo unset')"
check "[[ -v ]] unset" "unset" "$(timeout 3 $DEN -c '[[ -v nonexistent_var ]] && echo set || echo unset')"
check "[[ -v ]] HOME" "set" "$(timeout 3 $DEN -c '[[ -v HOME ]] && echo set || echo unset')"

# ===========================================================================
# 96. getopts
# ===========================================================================
check "getopts basic" "a foo" "$(timeout 3 $DEN -c 'getopts "a:b" opt -a foo; echo "$opt $OPTARG"')"

# ===========================================================================
# 97. Associative array keys
# ===========================================================================
check "assoc keys step" "key1 key2" "$(timeout 3 $DEN -c 'declare -A m; m[key1]=v1; m[key2]=v2; echo "${!m[@]}"')"
check "assoc keys inline" "2" "$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); echo ${#m[@]}')"

# ===========================================================================
# 98. local -i (integer attribute)
# ===========================================================================
check "local -i" "8" "$(timeout 3 $DEN -c 'f() { local -i x=5+3; echo $x; }; f')"

# ===========================================================================
# 99. read -ra (combined flags)
# ===========================================================================
check "read -ra" "3" "$(echo "a b c" | timeout 3 $DEN -c 'read -ra arr; echo ${#arr[@]}')"

# ===========================================================================
# 100. Arithmetic base conversion
# ===========================================================================
check "arith base16" "255" "$(timeout 3 $DEN -c 'echo $((16#ff))')"
check "arith base2" "10" "$(timeout 3 $DEN -c 'echo $((2#1010))')"
check "arith base8" "63" "$(timeout 3 $DEN -c 'echo $((8#77))')"

# ===========================================================================
# 101. ${var@op} transform operators
# ===========================================================================
check "transform @U" "HELLO WORLD" "$(timeout 3 $DEN -c 'x="Hello World"; echo ${x@U}')"
check "transform @L" "hello world" "$(timeout 3 $DEN -c 'x="Hello World"; echo ${x@L}')"
check "transform @u" "Hello world" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x@u}')"

# ===========================================================================
# 102. Negative array slice
# ===========================================================================
check "arr neg slice" "3 4 5" "$(timeout 3 $DEN -c 'arr=(1 2 3 4 5); echo ${arr[@]: -3}')"
check "arr neg slice 2" "d e" "$(timeout 3 $DEN -c 'arr=(a b c d e); echo ${arr[@]: -2}')"

# ===========================================================================
# 103. Associative array step-by-step assignment
# ===========================================================================
check "assoc step assign" "val1" "$(timeout 3 $DEN -c 'declare -A m; m[key1]=val1; echo ${m[key1]}')"
AKCOUNT=$(timeout 3 $DEN -c 'declare -A m; m[a]=1; m[b]=2; echo ${!m[@]}' | wc -w | tr -d ' ')
check "assoc keys count" "2" "$AKCOUNT"

# ===========================================================================
# 104. Brace expansion with step
# ===========================================================================
check "brace step" "1 3 5 7 9" "$(timeout 3 $DEN -c 'echo {1..10..2}')"
check "brace step 3" "1 4 7 10" "$(timeout 3 $DEN -c 'echo {1..10..3}')"
check "brace step rev" "10 8 6 4 2" "$(timeout 3 $DEN -c 'echo {10..1..2}')"

# ===========================================================================
# 105. ${var/#pat/rep} prefix and ${var/%pat/rep} suffix substitution
# ===========================================================================
check "subst prefix" "HEllo" "$(timeout 3 $DEN -c 'x="hello"; echo "${x/#he/HE}"')"
check "subst suffix" "helLO" "$(timeout 3 $DEN -c 'x="hello"; echo "${x/%lo/LO}"')"
check "subst prefix nomatch" "hello" "$(timeout 3 $DEN -c 'x="hello"; echo "${x/#xx/YY}"')"

# ===========================================================================
# 106. ${var@op} transform operators
# ===========================================================================
check "transform @Q" "'hello'" "$(timeout 3 $DEN -c "x=hello; echo \${x@Q}")"

# ===========================================================================
# 107. Special variables: PPID, BASHPID, EUID, UID
# ===========================================================================
check "PPID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $PPID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "BASHPID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $BASHPID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "EUID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $EUID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "UID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $UID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "PPID braced" "yes" "$(timeout 3 $DEN -c '[[ ${PPID} =~ ^[0-9]+$ ]] && echo yes || echo no')"

# ===========================================================================
# 108. String comparison in [[ ]]
# ===========================================================================
check "[[ a < b ]]" "yes" "$(timeout 3 $DEN -c '[[ a < b ]] && echo yes || echo no')"
check "[[ z < a ]]" "no" "$(timeout 3 $DEN -c '[[ z < a ]] && echo yes || echo no')"
check "[[ abc < def ]]" "yes" "$(timeout 3 $DEN -c '[[ abc < def ]] && echo yes || echo no')"
check "[[ z > a ]]" "yes" "$(timeout 3 $DEN -c '[[ z > a ]] && echo yes || echo no')"

# ===========================================================================
# 109. source builtin
# ===========================================================================
echo 'x=42' > /tmp/den_source_test.sh
check "source variable" "42" "$(timeout 3 $DEN -c 'source /tmp/den_source_test.sh; echo $x')"
check "dot source" "42" "$(timeout 3 $DEN -c '. /tmp/den_source_test.sh; echo $x')"
echo 'greet() { echo hi; }' > /tmp/den_source_func.sh
check "source function" "hi" "$(timeout 3 $DEN -c 'source /tmp/den_source_func.sh; greet')"
rm -f /tmp/den_source_test.sh /tmp/den_source_func.sh

# ===========================================================================
# 110. Arithmetic assignment
# ===========================================================================
check "arith assign x=5+3" "8" "$(timeout 3 $DEN -c 'echo $((x=5+3))')"
check "arith assign persist" "8 8" "$(timeout 3 $DEN -c 'echo $((x=5+3)); echo $x' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 111. Arithmetic increment/decrement
# ===========================================================================
check "pre-increment" "6" "$(timeout 3 $DEN -c 'x=5; echo $((++x))')"
check "post-increment" "5" "$(timeout 3 $DEN -c 'x=5; echo $((x++))')"
check "pre-decrement" "4" "$(timeout 3 $DEN -c 'x=5; echo $((--x))')"
check "post-decrement" "5" "$(timeout 3 $DEN -c 'x=5; echo $((x--))')"

# ===========================================================================
# 112. Compound assignment operators
# ===========================================================================
check "arith +=" "8" "$(timeout 3 $DEN -c 'x=5; echo $((x+=3))')"
check "arith -=" "7" "$(timeout 3 $DEN -c 'x=10; echo $((x-=3))')"
check "arith *=" "15" "$(timeout 3 $DEN -c 'x=5; echo $((x*=3))')"
check "arith /=" "5" "$(timeout 3 $DEN -c 'x=15; echo $((x/=3))')"
check "arith %=" "2" "$(timeout 3 $DEN -c 'x=17; echo $((x%=5))')"

# ===========================================================================
# 113. [[ && ]] and [[ || ]] inside double brackets
# ===========================================================================
check "[[ && ]]" "yes" "$(timeout 3 $DEN -c '[[ 1 -eq 1 && 2 -eq 2 ]] && echo yes || echo no')"
check "[[ || ]]" "yes" "$(timeout 3 $DEN -c '[[ 1 -eq 2 || 2 -eq 2 ]] && echo yes || echo no')"
check "[[ && false ]]" "no" "$(timeout 3 $DEN -c '[[ 1 -eq 1 && 2 -eq 3 ]] && echo yes || echo no')"

# ===========================================================================
# 114. File tests (stat-based, not requiring open)
# ===========================================================================
check "[[ -f /etc/hosts ]]" "yes" "$(timeout 3 $DEN -c '[[ -f /etc/hosts ]] && echo yes || echo no')"
check "[[ -d /tmp ]]" "yes" "$(timeout 3 $DEN -c '[[ -d /tmp ]] && echo yes || echo no')"
check "[[ -e /etc/hosts ]]" "yes" "$(timeout 3 $DEN -c '[[ -e /etc/hosts ]] && echo yes || echo no')"

# ===========================================================================
# 115. FD duplication shorthand >&N / <&N
# ===========================================================================
check ">&2 redirect" "hello" "$(timeout 3 $DEN -c 'echo hello >&2' 2>&1)"
check "[[ paren group ]]" "yes" "$(timeout 3 $DEN -c '[[ ( 1 -eq 1 ) && ( 2 -eq 2 ) ]] && echo yes || echo no')"

# ===========================================================================
# 116. Case glob patterns
# ===========================================================================
check "case h*o glob" "matched" "$(timeout 3 $DEN -c 'x=hello; case $x in h*o) echo matched;; *) echo no;; esac')"
check "case h?llo glob" "matched" "$(timeout 3 $DEN -c 'x=hello; case $x in h?llo) echo matched;; *) echo no;; esac')"
check "case [a-z]* glob" "matched" "$(timeout 3 $DEN -c 'x=hello; case $x in [a-z]*) echo matched;; *) echo no;; esac')"
check "case or pattern" "matched" "$(timeout 3 $DEN -c 'x=b; case $x in a|b) echo matched;; *) echo no;; esac')"

# ===========================================================================
# 117. (( )) arithmetic command with && / ||
# ===========================================================================
check "(( )) && true" "yes" "$(timeout 3 $DEN -c '(( 5 > 3 )) && echo yes || echo no')"
check "(( )) && false" "no" "$(timeout 3 $DEN -c '(( 3 > 5 )) && echo yes || echo no')"
check "(( )) exit code" "0" "$(timeout 3 $DEN -c '(( 5 > 3 )); echo $?')"

# ===========================================================================
# 118. HOSTNAME variable
# ===========================================================================
check "HOSTNAME not empty" "yes" "$(timeout 3 $DEN -c '[[ -n $HOSTNAME ]] && echo yes || echo no')"

# ===========================================================================
# 119. Control flow piping (for/while/if/case ... | cmd)
# ===========================================================================
check "for pipe" "A
B
C" "$(timeout 3 $DEN -c 'for f in a b c; do echo "$f"; done | tr a-z A-Z')"
check "for pipe wc" "3" "$(timeout 3 $DEN -c 'for i in 1 2 3; do echo "$i"; done | wc -l | tr -d " "')"
check "for pipe sort" "a
b
c" "$(timeout 3 $DEN -c 'for f in c a b; do echo "$f"; done | sort')"
check "for pipe chain" "A
B
C" "$(timeout 3 $DEN -c 'for f in c a b; do echo "$f"; done | sort | tr a-z A-Z')"
check "if pipe" "HELLO" "$(timeout 3 $DEN -c 'if true; then echo hello; fi | tr a-z A-Z')"
check "if else pipe" "YES" "$(timeout 3 $DEN -c 'if false; then echo no; else echo yes; fi | tr a-z A-Z')"
check "if multi pipe" "3" "$(timeout 3 $DEN -c 'if true; then echo a; echo b; echo c; fi | wc -l | tr -d " "')"
check "case pipe" "MATCHED" "$(timeout 3 $DEN -c 'x=hello; case $x in hello) echo "matched";; esac | tr a-z A-Z')"
check "for pipe grep" "b" "$(timeout 3 $DEN -c 'for f in a b c; do echo "$f"; done | grep b')"

# ===========================================================================
# 120. Subshell piping ((cmd1; cmd2) | cmd)
# ===========================================================================
check "subshell pipe wc" "2" "$(timeout 3 $DEN -c '(echo hello; echo world) | wc -l | tr -d " "')"
check "subshell pipe tr" "HELLO
WORLD" "$(timeout 3 $DEN -c '(echo hello; echo world) | tr a-z A-Z')"
check "subshell pipe sort" "a
b
c" "$(timeout 3 $DEN -c '(echo c; echo a; echo b) | sort')"
check "subshell pipe chain" "A
B
C" "$(timeout 3 $DEN -c '(echo c; echo a; echo b) | sort | tr a-z A-Z')"
check "simple subshell" "hello
world" "$(timeout 3 $DEN -c '(echo hello; echo world)')"
check "subshell var isolation" "outer" "$(timeout 3 $DEN -c 'x=outer; (x=inner); echo "$x"')"
check "nested subshell pipe" "2" "$(timeout 3 $DEN -c '(echo a; (echo b)) | wc -l | tr -d " "')"

# ===========================================================================
# 121. Let arithmetic evaluation
# ===========================================================================
check "let add" "10" "$(timeout 3 $DEN -c 'let x=5+5; echo $x')"
check "let mult" "20" "$(timeout 3 $DEN -c 'let x=4*5; echo $x')"
check "let sub" "3" "$(timeout 3 $DEN -c 'let x=8-5; echo $x')"
check "let div" "4" "$(timeout 3 $DEN -c 'let x=20/5; echo $x')"
check "let literal" "42" "$(timeout 3 $DEN -c 'let x=42; echo $x')"

# ===========================================================================
# 122. Control flow keyword with suffix (done|, fi;, etc.)
# ===========================================================================
check "done semicolon" "a
b" "$(timeout 3 $DEN -c 'for f in a b; do echo "$f"; done; echo ""' | head -2)"
check "done pipe inline" "2" "$(timeout 3 $DEN -c 'for f in a b; do echo "$f"; done | wc -l | tr -d " "')"

# ===========================================================================
# 123. Heredoc in -c mode
# ===========================================================================
check "herestring basic" "hello world" "$(timeout 3 $DEN -c 'cat <<< "hello world"')"
check "herestring var" "hello world" "$(timeout 3 $DEN -c 'x="hello world"; cat <<< "$x"')"

# ===========================================================================
# 124. Command substitution with control flow pipe
# ===========================================================================
check "subst for pipe" "X
Y
Z" "$(timeout 3 $DEN -c 'result=$(for f in x y z; do echo "$f"; done | tr a-z A-Z); echo "$result"')"

# ===========================================================================
# 125. Case statement with quoted values and glob patterns
# ===========================================================================
check "case quoted exact" "matched" "$(timeout 3 $DEN -c 'case "hello" in hello) echo matched;; *) echo no;; esac')"
check "case quoted glob prefix" "matched" "$(timeout 3 $DEN -c 'case "hello" in h*) echo matched;; *) echo no;; esac')"
check "case quoted glob suffix" "matched" "$(timeout 3 $DEN -c 'case "hello" in *lo) echo matched;; *) echo no;; esac')"
check "case quoted pipe pattern" "pipe" "$(timeout 3 $DEN -c 'case "hello" in hi|hello) echo pipe;; *) echo no;; esac')"
check "case single quoted" "matched" "$(timeout 3 $DEN -c "case 'hello' in hello) echo matched;; *) echo no;; esac")"
check "case var pattern" "varpat" "$(timeout 3 $DEN -c 'PAT=hello; case "hello" in $PAT) echo varpat;; *) echo no;; esac')"
check "case quoted both" "yes" "$(timeout 3 $DEN -c 'case "abc" in "abc") echo yes;; *) echo no;; esac')"
check "case unquoted ok" "yes" "$(timeout 3 $DEN -c 'case hello in hello) echo yes;; *) echo no;; esac')"

# ===========================================================================
# 126. Nested quotes in $() command substitution
# ===========================================================================
check "nested dq in cmd sub" "result: hello world" "$(timeout 3 $DEN -c 'echo "result: $(echo "hello world")"')"
check "nested dq pipe" "3" "$(timeout 3 $DEN -c 'echo "$(echo -e "a\nb\nc" | wc -l | tr -d " ")"')"
check "multi cmd sub dq" "hello world" "$(timeout 3 $DEN -c 'echo "$(echo "hello") $(echo "world")"')"
check "deep nested cmd sub" "deep" "$(timeout 3 $DEN -c 'echo "$(echo "$(echo "deep")")"')"

# ===========================================================================
# 127. Export variables visible in $()
# ===========================================================================
check "export in cmd sub" "hello" "$(timeout 3 $DEN -c 'export X=hello; echo $(echo $X)')"
check "export dq cmd sub" "val: world" "$(timeout 3 $DEN -c 'export X=world; echo "val: $(echo "$X")"')"
check "export name cmd sub" "done" "$(timeout 3 $DEN -c 'Y=done; export Y; echo $(echo $Y)')"

# ===========================================================================
# 128. Per-command temporary variable assignment (VAR=val cmd)
# ===========================================================================
check "IFS read colon" "a b c" "$(echo 'a:b:c' | timeout 3 $DEN -c 'IFS=: read x y z; echo "$x $y $z"')"
check "temp var env" "bar" "$(timeout 3 $DEN -c 'FOO=bar env | grep "^FOO=" | cut -d= -f2')"
check "temp var restore" "test
original" "$(timeout 3 $DEN -c 'X=original; X=temp echo test; echo $X')"
check "temp var unset after" "ok
unset" "$(timeout 3 $DEN -c 'NEWVAR=hello echo ok; echo ${NEWVAR:-unset}')"
check "multi temp var" "1 2" "$(timeout 3 $DEN -c 'A=1 B=2 env | grep -E "^(A|B)=" | sort | cut -d= -f2 | tr "\n" " " | sed "s/ $//"')"
check "IFS comma heredoc" "x y z" "$(timeout 3 $DEN -c 'IFS=, read -r a b c <<< "x,y,z"; echo "$a $b $c"')"

# ===========================================================================
# 129. Multiline strings in -c mode
# ===========================================================================
check "multiline dq var" "line1
line2" "$(timeout 3 $DEN -c 'x="line1
line2"; echo "$x"')"
check "multiline sq var" "line1
line2" "$(timeout 3 $DEN -c "x='line1
line2'; echo \"\$x\"")"
check "multiline heredoc -c" "hello world" "$(timeout 3 $DEN -c 'cat << EOF
hello world
EOF')"

# ===========================================================================
# 130. Glob suppression in quotes and escaped dollar
# ===========================================================================
check "dq no glob" "/dev/nul*" "$(timeout 3 $DEN -c 'echo "/dev/nul*"')"
check "sq no glob" "/dev/nul*" "$(timeout 3 $DEN -c "echo '/dev/nul*'")"
check "unquoted glob" "/dev/null" "$(timeout 3 $DEN -c 'echo /dev/nul*')"
check "escaped dollar dq" '$HOME' "$(timeout 3 $DEN -c 'echo "\$HOME"')"
check "escaped dollar cost" 'cost is $5' "$(timeout 3 $DEN -c 'echo "cost is \$5"')"

# ===========================================================================
# 131. Functions visible in command substitution
# ===========================================================================
check "func in cmd sub" "hello" "$(timeout 3 $DEN -c 'f() { echo hello; }; echo $(f)')"
check "func result var" "hello" "$(timeout 3 $DEN -c 'f() { echo hello; }; result=$(f); echo $result')"
check "recursive func" "120" "$(timeout 5 $DEN -c 'fact() { if [ $1 -le 1 ]; then echo 1; else local n=$1; local prev=$(fact $((n-1))); echo $((n * prev)); fi; }; fact 5')"

# ===========================================================================
# Results
# ===========================================================================
echo ""
if [ $FAIL -gt 0 ]; then
    echo -e "$FAILURES"
fi
TOTAL=$((PASS+FAIL))
echo "Results: $PASS / $TOTAL passed ($SKIP skipped)"
if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED!"
    exit 0
else
    echo "$FAIL test(s) failed"
    exit 1
fi
