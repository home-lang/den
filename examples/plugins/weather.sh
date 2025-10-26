#!/bin/bash
# Example Plugin: Weather Display (Shell Script)
# Place in ~/.config/den/plugins/weather.sh
#
# This is a simple shell-based plugin that displays weather information
# in the prompt using wttr.in API

DEN_PLUGIN_NAME="weather"
DEN_PLUGIN_VERSION="1.0.0"
DEN_PLUGIN_DESCRIPTION="Display weather information in prompt"

# Configuration
WEATHER_LOCATION="${WEATHER_LOCATION:-auto}"
WEATHER_FORMAT="${WEATHER_FORMAT:-%c%t}"  # icon + temperature
WEATHER_CACHE_FILE="$HOME/.cache/den/weather.cache"
WEATHER_CACHE_DURATION=1800  # 30 minutes

# Get cached weather or fetch new
get_weather() {
    local cache_file="$WEATHER_CACHE_FILE"
    local cache_age=0

    # Check cache
    if [ -f "$cache_file" ]; then
        cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)))
    fi

    # Use cache if recent
    if [ $cache_age -lt $WEATHER_CACHE_DURATION ] && [ -f "$cache_file" ]; then
        cat "$cache_file"
        return
    fi

    # Fetch new weather data
    local weather
    weather=$(curl -s "wttr.in/${WEATHER_LOCATION}?format=${WEATHER_FORMAT}" 2>/dev/null)

    if [ -n "$weather" ]; then
        mkdir -p "$(dirname "$cache_file")"
        echo "$weather" > "$cache_file"
        echo "$weather"
    fi
}

# Hook: pre_prompt
# Called before prompt is rendered
hook_pre_prompt() {
    local weather
    weather=$(get_weather)

    if [ -n "$weather" ]; then
        export DEN_WEATHER="$weather "
    fi
}

# Configuration handler
plugin_configure() {
    local key="$1"
    local value="$2"

    case "$key" in
        location)
            export WEATHER_LOCATION="$value"
            ;;
        format)
            export WEATHER_FORMAT="$value"
            ;;
        cache_duration)
            export WEATHER_CACHE_DURATION="$value"
            ;;
    esac
}

# Entry point
case "${1:-}" in
    info)
        echo "name: $DEN_PLUGIN_NAME"
        echo "version: $DEN_PLUGIN_VERSION"
        echo "description: $DEN_PLUGIN_DESCRIPTION"
        ;;
    configure)
        plugin_configure "$2" "$3"
        ;;
    hook)
        hook_pre_prompt
        ;;
    *)
        echo "Usage: $0 {info|configure|hook}"
        exit 1
        ;;
esac
