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
check "multiple pipes" "2" "$(timeout 3 $DEN -c 'echo -e "aa\nbb\ncc" | grep -c "[ab]"')"

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
