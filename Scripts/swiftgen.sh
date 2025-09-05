#!/bin/bash

# SwiftGen Build Phase Script
# This script runs SwiftGen to generate Swift code from localization files

set -e

# Change to project root directory
cd "$SRCROOT"

# Check if SwiftGen is available
if which swiftgen >/dev/null; then
    echo "Running SwiftGen..."
    swiftgen
    echo "SwiftGen completed successfully"
else
    echo "Warning: SwiftGen not found. Please install with 'brew install swiftgen'"
    echo "Skipping SwiftGen generation."
fi