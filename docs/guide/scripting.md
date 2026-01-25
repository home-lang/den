# Scripting

Den supports shell scripting with POSIX-compatible syntax, allowing you to automate complex tasks.

## Basic Script Structure

```bash
#!/usr/bin/env den

# Comments start with #
# This is a basic Den script

# Variables
NAME="World"
echo "Hello, $NAME!"

# Exit with status
exit 0
```

## Variables

### Setting Variables

```bash
# Simple assignment (no spaces around =)
NAME="value"
COUNT=42
EMPTY=""

# Command substitution
CURRENT_DIR=$(pwd)
DATE=$(date +%Y-%m-%d)
FILES=$(ls *.txt)

# Environment variables
export PATH="$HOME/bin:$PATH"
export DEBUG=true
```

### Using Variables

```bash
# Basic expansion
echo $NAME
echo "Hello, $NAME"

# Braced expansion (recommended)
echo "${NAME}"
echo "${NAME}_suffix"

# Default values
echo "${NAME:-default}"      # Use default if unset
echo "${NAME:=default}"      # Set and use default if unset

# Length
echo "${#NAME}"              # String length
```

### Special Variables

| Variable | Description |
|----------|-------------|
| `$?` | Exit status of last command |
| `$$` | Current process ID |
| `$!` | PID of last background process |
| `$_` | Last argument of previous command |
| `$0` | Script name |
| `$1-$9` | Positional parameters |
| `$@` | All positional parameters (as separate words) |
| `$*` | All positional parameters (as single string) |
| `$#` | Number of positional parameters |

### Example: Using Special Variables

```bash
#!/usr/bin/env den

echo "Script: $0"
echo "First arg: $1"
echo "All args: $@"
echo "Arg count: $#"

some_command
echo "Exit status: $?"
```

## Conditionals

### If Statements

```bash
#!/usr/bin/env den

# Basic if statement
if test -f "config.txt"; then
    echo "Config exists"
fi

# If-else
if test -d "/tmp/mydir"; then
    echo "Directory exists"
else
    mkdir /tmp/mydir
    echo "Directory created"
fi

# If-elif-else
if test "$1" = "start"; then
    echo "Starting..."
elif test "$1" = "stop"; then
    echo "Stopping..."
else
    echo "Usage: $0 {start|stop}"
    exit 1
fi
```

### Test Conditions

#### File Tests

| Test | Description |
|------|-------------|
| `-e FILE` | File exists |
| `-f FILE` | Regular file |
| `-d DIR` | Directory |
| `-r FILE` | Readable |
| `-w FILE` | Writable |
| `-x FILE` | Executable |
| `-s FILE` | File size > 0 |

#### String Tests

| Test | Description |
|------|-------------|
| `-z STRING` | String is empty |
| `-n STRING` | String is not empty |
| `S1 = S2` | Strings are equal |
| `S1 != S2` | Strings are not equal |

#### Numeric Tests

| Test | Description |
|------|-------------|
| `N1 -eq N2` | Equal |
| `N1 -ne N2` | Not equal |
| `N1 -lt N2` | Less than |
| `N1 -le N2` | Less than or equal |
| `N1 -gt N2` | Greater than |
| `N1 -ge N2` | Greater than or equal |

### Boolean Operators

```bash
# AND
if test -f "file1" && test -f "file2"; then
    echo "Both files exist"
fi

# OR
if test -f "config.json" || test -f "config.yaml"; then
    echo "Config found"
fi

# NOT
if ! test -d "/tmp/cache"; then
    mkdir /tmp/cache
fi
```

## Loops

### For Loops

```bash
#!/usr/bin/env den

# Iterate over list
for name in Alice Bob Charlie; do
    echo "Hello, $name"
done

# Iterate over files
for file in *.txt; do
    echo "Processing $file"
    cat "$file"
done

# Iterate over command output
for dir in $(ls -d */); do
    echo "Directory: $dir"
done

# Brace expansion
for i in {1..5}; do
    echo "Number: $i"
done

# Range with step
for i in {0..10..2}; do
    echo "Even: $i"
done
```

### While Loops

```bash
#!/usr/bin/env den

# Counter loop
COUNT=0
while test $COUNT -lt 5; do
    echo "Count: $COUNT"
    COUNT=$((COUNT + 1))
done

# Read file line by line
while read line; do
    echo "Line: $line"
done < input.txt

# Infinite loop (use with care)
while true; do
    echo "Running..."
    sleep 1
done
```

## Arithmetic

### Arithmetic Expansion

```bash
#!/usr/bin/env den

# Basic arithmetic
echo $((1 + 2))       # 3
echo $((10 - 3))      # 7
echo $((4 * 5))       # 20
echo $((20 / 4))      # 5
echo $((17 % 5))      # 2
echo $((2 ** 8))      # 256

# Variables in arithmetic
X=10
Y=3
echo $((X + Y))       # 13
echo $((X * Y))       # 30

# Increment
COUNT=0
COUNT=$((COUNT + 1))
echo $COUNT           # 1
```

## Command Substitution

```bash
#!/usr/bin/env den

# Capture command output
CURRENT_DATE=$(date)
echo "Today is: $CURRENT_DATE"

# Use in strings
echo "You are in: $(pwd)"

# Nested substitution
FILE_COUNT=$(ls $(pwd) | wc -l)
echo "Files in current directory: $FILE_COUNT"

# As argument
mkdir "backup-$(date +%Y%m%d)"
```

## Input and Output

### Reading Input

```bash
#!/usr/bin/env den

# Read a line
echo "Enter your name:"
read NAME
echo "Hello, $NAME!"

# Read with prompt
read -p "Enter value: " VALUE
echo "You entered: $VALUE"

# Read multiple values
echo "Enter first and last name:"
read FIRST LAST
echo "Hello, $FIRST $LAST"
```

### Output

```bash
#!/usr/bin/env den

# Standard output
echo "Normal message"
printf "Formatted: %s - %d\n" "text" 42

# Standard error
echo "Error message" >&2

# Suppress output
command > /dev/null 2>&1
```

## Error Handling

```bash
#!/usr/bin/env den

# Check command success
if ! mkdir /tmp/mydir 2>/dev/null; then
    echo "Failed to create directory"
    exit 1
fi

# Handle specific error
if ! test -f "required.conf"; then
    echo "Error: required.conf not found"
    exit 1
fi

# Exit on error pattern
cp important.txt backup/
if test $? -ne 0; then
    echo "Backup failed!"
    exit 1
fi
echo "Backup successful"
```

## Complete Script Examples

### Build Script

```bash
#!/usr/bin/env den
# build.sh - Build project

echo "Building project..."

# Clean old builds
if test -d "build"; then
    rm -rf build
fi

# Create build directory
mkdir -p build

# Compile
if ! zig build -Doptimize=ReleaseFast; then
    echo "Build failed!"
    exit 1
fi

# Copy artifacts
cp zig-out/bin/myapp build/

echo "Build complete!"
```

### Deployment Script

```bash
#!/usr/bin/env den
# deploy.sh - Deploy to server

SERVER="user@server.com"
REMOTE_PATH="/var/www/app"

# Check if build exists
if ! test -f "build/app"; then
    echo "Error: Build not found. Run build.sh first."
    exit 1
fi

echo "Deploying to $SERVER..."

# Upload files
scp -r build/* "$SERVER:$REMOTE_PATH/"

# Restart service
ssh "$SERVER" "sudo systemctl restart myapp"

echo "Deployment complete!"
```

### Log Rotation Script

```bash
#!/usr/bin/env den
# rotate-logs.sh - Rotate log files

LOG_DIR="/var/log/myapp"
MAX_LOGS=5

pushd "$LOG_DIR"

# Rotate existing logs
for i in {4..1}; do
    if test -f "app.log.$i"; then
        mv "app.log.$i" "app.log.$((i + 1))"
    fi
done

# Move current log
if test -f "app.log"; then
    mv app.log app.log.1
    touch app.log
fi

# Remove old logs
for file in app.log.*; do
    NUM="${file##*.}"
    if test "$NUM" -gt "$MAX_LOGS"; then
        rm "$file"
    fi
done

popd

echo "Log rotation complete"
```

## Best Practices

1. **Always quote variables**: `"$VAR"` not `$VAR`
2. **Check command success**: Use `if` or check `$?`
3. **Provide usage information**: Include help text
4. **Use meaningful exit codes**: 0 for success, non-zero for errors
5. **Comment your code**: Explain complex logic
6. **Handle edge cases**: Empty input, missing files

## Next Steps

Learn about migrating from Bash in the [Migration Guide](/guide/bash-migration).
