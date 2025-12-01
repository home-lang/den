# Den Shell Scripting Guide

This guide covers writing scripts and using advanced shell features in Den Shell.

## Table of Contents

- [Variables](#variables)
- [Control Flow](#control-flow)
- [Functions](#functions)
- [Loops](#loops)
- [Arrays](#arrays)
- [Arithmetic](#arithmetic)
- [String Operations](#string-operations)
- [Input/Output](#inputoutput)
- [Error Handling](#error-handling)
- [Best Practices](#best-practices)

---

## Variables

### Basic Variables

```bash
# Assignment (no spaces around =)
name="Den Shell"
count=42

# Using variables
echo $name
echo "Welcome to $name"
echo "Count is: ${count}"
```

### Special Variables

| Variable | Description |
|----------|-------------|
| `$?` | Exit status of last command |
| `$$` | Current shell's PID |
| `$!` | PID of last background process |
| `$_` | Last argument of previous command |
| `$0` | Script name |
| `$1-$9` | Positional parameters |
| `$@` | All positional parameters (as separate words) |
| `$*` | All positional parameters (as single word) |
| `$#` | Number of positional parameters |

### Parameter Expansion

```bash
# Default values
echo ${var:-default}      # Use "default" if var is unset or empty
echo ${var:=default}      # Set var to "default" if unset or empty
echo ${var:+alternate}    # Use "alternate" if var is set and non-empty
echo ${var:?error msg}    # Error if var is unset or empty

# String manipulation
name="hello world"
echo ${name#he}           # Remove shortest prefix "he" -> "llo world"
echo ${name##*o}          # Remove longest prefix "*o" -> "rld"
echo ${name%ld}           # Remove shortest suffix "ld" -> "hello wor"
echo ${name%%o*}          # Remove longest suffix "o*" -> "hell"

# Length and substring
echo ${#name}             # Length: 11
echo ${name:0:5}          # Substring: "hello"
echo ${name:6}            # From position 6: "world"

# Case conversion
echo ${name^^}            # Uppercase: "HELLO WORLD"
echo ${name,,}            # Lowercase: "hello world"

# Search and replace
echo ${name/world/den}    # Replace first: "hello den"
echo ${name//o/0}         # Replace all: "hell0 w0rld"
```

---

## Control Flow

### If Statements

```bash
# Basic if
if [ $count -gt 10 ]; then
    echo "Count is greater than 10"
fi

# If-else
if [ -f "file.txt" ]; then
    echo "File exists"
else
    echo "File not found"
fi

# If-elif-else
if [ $status -eq 0 ]; then
    echo "Success"
elif [ $status -eq 1 ]; then
    echo "Warning"
else
    echo "Error"
fi

# Extended test with [[
if [[ $name == "den"* ]]; then
    echo "Name starts with 'den'"
fi

if [[ $string =~ ^[0-9]+$ ]]; then
    echo "String is numeric"
fi
```

### Test Operators

**File Tests:**
| Operator | Description |
|----------|-------------|
| `-e file` | File exists |
| `-f file` | Regular file |
| `-d file` | Directory |
| `-r file` | Readable |
| `-w file` | Writable |
| `-x file` | Executable |
| `-s file` | File size > 0 |
| `-L file` | Symbolic link |

**String Tests:**
| Operator | Description |
|----------|-------------|
| `-z str` | String is empty |
| `-n str` | String is not empty |
| `str1 = str2` | Strings are equal |
| `str1 != str2` | Strings are not equal |

**Numeric Tests:**
| Operator | Description |
|----------|-------------|
| `-eq` | Equal |
| `-ne` | Not equal |
| `-lt` | Less than |
| `-le` | Less than or equal |
| `-gt` | Greater than |
| `-ge` | Greater than or equal |

### Case Statements

```bash
case $option in
    start)
        echo "Starting service..."
        ;;
    stop)
        echo "Stopping service..."
        ;;
    restart)
        echo "Restarting service..."
        ;;
    *)
        echo "Unknown option: $option"
        ;;
esac
```

---

## Functions

### Basic Functions

```bash
# Function definition (two styles)
function greet {
    echo "Hello, $1!"
}

# Or
greet() {
    echo "Hello, $1!"
}

# Call function
greet "World"           # Output: Hello, World!
```

### Functions with Return Values

```bash
# Return exit status
is_even() {
    if (( $1 % 2 == 0 )); then
        return 0    # True
    else
        return 1    # False
    fi
}

if is_even 4; then
    echo "4 is even"
fi

# Return string value via echo
get_greeting() {
    local name=$1
    echo "Hello, $name!"
}

result=$(get_greeting "Den")
echo $result
```

### Local Variables

```bash
outer_func() {
    local message="Local to outer_func"
    echo $message
}

outer_func
echo $message    # Empty - message is local
```

### Function Parameters

```bash
print_args() {
    echo "Number of arguments: $#"
    echo "All arguments: $@"
    echo "First argument: $1"
    echo "Second argument: $2"
}

print_args "one" "two" "three"
```

---

## Loops

### For Loops

```bash
# Iterate over list
for item in apple banana cherry; do
    echo "Fruit: $item"
done

# Iterate over range
for i in {1..5}; do
    echo "Number: $i"
done

# Iterate with step
for i in {0..10..2}; do
    echo "Even: $i"
done

# C-style for loop
for ((i=0; i<5; i++)); do
    echo "Index: $i"
done

# Iterate over files
for file in *.txt; do
    echo "Processing: $file"
done

# Iterate over command output
for user in $(cat users.txt); do
    echo "User: $user"
done
```

### While Loops

```bash
# Basic while
count=0
while [ $count -lt 5 ]; do
    echo "Count: $count"
    count=$((count + 1))
done

# Read lines from file
while read -r line; do
    echo "Line: $line"
done < file.txt

# Infinite loop with break
while true; do
    read -p "Enter command (quit to exit): " cmd
    if [ "$cmd" = "quit" ]; then
        break
    fi
    echo "You entered: $cmd"
done
```

### Until Loops

```bash
count=0
until [ $count -ge 5 ]; do
    echo "Count: $count"
    count=$((count + 1))
done
```

### Select Loops (Interactive Menus)

```bash
PS3="Choose an option: "
select opt in "Start" "Stop" "Restart" "Quit"; do
    case $opt in
        Start)   echo "Starting..."; break ;;
        Stop)    echo "Stopping..."; break ;;
        Restart) echo "Restarting..."; break ;;
        Quit)    echo "Goodbye!"; break ;;
        *)       echo "Invalid option" ;;
    esac
done
```

### Loop Control

```bash
# Break - exit loop
for i in {1..10}; do
    if [ $i -eq 5 ]; then
        break
    fi
    echo $i
done

# Continue - skip iteration
for i in {1..10}; do
    if [ $((i % 2)) -eq 0 ]; then
        continue
    fi
    echo $i    # Prints odd numbers only
done
```

---

## Arrays

### Indexed Arrays

```bash
# Declaration
fruits=("apple" "banana" "cherry")

# Access elements
echo ${fruits[0]}         # apple
echo ${fruits[1]}         # banana
echo ${fruits[@]}         # All elements
echo ${#fruits[@]}        # Array length: 3

# Append
fruits+=("date")

# Iterate
for fruit in "${fruits[@]}"; do
    echo "Fruit: $fruit"
done

# Slice
echo ${fruits[@]:1:2}     # banana cherry
```

### Associative Arrays

```bash
# Declaration
declare -A colors
colors[red]="#FF0000"
colors[green]="#00FF00"
colors[blue]="#0000FF"

# Access
echo ${colors[red]}       # #FF0000

# Keys and values
echo ${!colors[@]}        # red green blue (keys)
echo ${colors[@]}         # All values

# Iterate
for key in "${!colors[@]}"; do
    echo "$key: ${colors[$key]}"
done
```

---

## Arithmetic

### Arithmetic Expansion

```bash
# Basic operations
echo $((5 + 3))           # 8
echo $((10 - 4))          # 6
echo $((6 * 7))           # 42
echo $((15 / 3))          # 5
echo $((17 % 5))          # 2
echo $((2 ** 10))         # 1024 (power)

# Compound assignment
count=5
((count++))               # Increment
((count--))               # Decrement
((count += 10))           # Add 10
((count *= 2))            # Multiply by 2

# Comparison (returns 0=true, 1=false)
((5 > 3)) && echo "true"
((5 == 5)) && echo "equal"

# Ternary operator
max=$(( a > b ? a : b ))

# Bitwise operations
echo $((5 & 3))           # AND: 1
echo $((5 | 3))           # OR: 7
echo $((5 ^ 3))           # XOR: 6
echo $((~5))              # NOT
echo $((5 << 2))          # Left shift: 20
echo $((20 >> 2))         # Right shift: 5

# Number bases
echo $((0xFF))            # Hex: 255
echo $((0755))            # Octal: 493
echo $((0b1010))          # Binary: 10
```

### The calc Builtin

```bash
calc "2 + 2"              # 4
calc "sqrt(16)"           # 4
calc "sin(3.14159/2)"     # ~1
calc "(10 + 5) * 2"       # 30
```

---

## String Operations

### String Manipulation

```bash
str="Hello, World!"

# Length
echo ${#str}              # 13

# Substring
echo ${str:0:5}           # Hello
echo ${str:7}             # World!
echo ${str: -6}           # World! (space before -)

# Search and replace
echo ${str/World/Den}     # Hello, Den!
echo ${str//o/0}          # Hell0, W0rld!

# Case conversion
echo ${str^^}             # HELLO, WORLD!
echo ${str,,}             # hello, world!

# Remove pattern
path="/home/user/file.txt"
echo ${path##*/}          # file.txt (basename)
echo ${path%/*}           # /home/user (dirname)
```

### String Comparison

```bash
str1="hello"
str2="world"

# Equality
if [ "$str1" = "$str2" ]; then
    echo "Equal"
fi

# Pattern matching with [[
if [[ $str1 == h* ]]; then
    echo "Starts with h"
fi

# Regex matching
if [[ $str1 =~ ^[a-z]+$ ]]; then
    echo "All lowercase letters"
fi
```

---

## Input/Output

### Reading Input

```bash
# Basic read
echo "Enter your name:"
read name
echo "Hello, $name!"

# Read with prompt
read -p "Enter your age: " age

# Read silently (for passwords)
read -s -p "Password: " password
echo

# Read with timeout
read -t 5 -p "Quick! Enter something: " quick

# Read into array
read -a items -p "Enter items (space-separated): "
echo "First item: ${items[0]}"

# Read specific number of characters
read -n 1 -p "Press any key..."

# Read with custom delimiter
read -d ':' -p "Enter until colon: " value
```

### Output

```bash
# Echo
echo "Simple output"
echo -n "No newline"
echo -e "Tab:\tNewline:\nDone"

# Printf (formatted output)
printf "Name: %s, Age: %d\n" "John" 25
printf "%-10s %5d\n" "Item" 42     # Left-align string, right-align number
printf "%08d\n" 42                  # Zero-pad: 00000042
printf "%.2f\n" 3.14159             # Float: 3.14
```

### Redirection

```bash
# Output to file
echo "Hello" > file.txt       # Overwrite
echo "World" >> file.txt      # Append

# Input from file
while read line; do
    echo "$line"
done < input.txt

# Redirect stderr
command 2> errors.log

# Redirect both stdout and stderr
command &> output.log
command > output.log 2>&1

# Discard output
command > /dev/null 2>&1

# Here document
cat << EOF
This is a multi-line
string that preserves
formatting.
EOF

# Here string
cat <<< "Single line input"
```

---

## Error Handling

### Exit Codes

```bash
# Check exit status
command
if [ $? -eq 0 ]; then
    echo "Success"
else
    echo "Failed with code $?"
fi

# Exit with code
exit 0    # Success
exit 1    # Error
```

### Shell Options

```bash
# Exit on error
set -e

# Exit on undefined variable
set -u

# Print commands before execution (debug)
set -x

# Pipeline failure detection
set -o pipefail

# Combine options
set -euo pipefail
```

### Trap for Cleanup

```bash
# Cleanup function
cleanup() {
    echo "Cleaning up..."
    rm -f /tmp/tempfile.$$
}

# Set trap
trap cleanup EXIT          # Run on exit
trap cleanup SIGINT        # Run on Ctrl+C
trap cleanup ERR           # Run on error (with set -e)

# Create temp file
echo "data" > /tmp/tempfile.$$
# ... do work ...
# cleanup runs automatically on exit
```

### Error Messages

```bash
# Print to stderr
echo "Error: Something went wrong" >&2

# Die function
die() {
    echo "ERROR: $1" >&2
    exit ${2:-1}
}

# Usage
[ -f "config.txt" ] || die "Config file not found" 2
```

---

## Best Practices

### Script Header

```bash
#!/usr/bin/env den
# Description: Brief description of the script
# Usage: script.sh [options] <args>
# Author: Your Name
# Date: 2025-01-01

set -euo pipefail
```

### Quote Variables

```bash
# Always quote variables to prevent word splitting
name="John Doe"
echo "$name"            # Correct
echo $name              # May cause issues with spaces

# Exception: Inside [[ ]] or (( ))
if [[ $name == "John Doe" ]]; then
    echo "Match"
fi
```

### Use Functions

```bash
# Break script into functions for readability
main() {
    parse_args "$@"
    validate_input
    process_data
    output_results
}

parse_args() {
    # Parse command-line arguments
    while getopts "hv" opt; do
        case $opt in
            h) show_help; exit 0 ;;
            v) VERBOSE=1 ;;
        esac
    done
}

# Run main function
main "$@"
```

### Check Command Existence

```bash
# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if ! command_exists curl; then
    echo "Error: curl is required"
    exit 1
fi
```

### Temporary Files

```bash
# Create temp file safely
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT

# Use the temp file
echo "data" > "$tmpfile"
```

### Logging

```bash
# Simple logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log "Starting script"
log_error "Something went wrong"
```

---

## See Also

- [Builtin Commands](./BUILTINS.md)
- [Configuration Guide](./config.md)
- [Architecture Overview](./ARCHITECTURE.md)
