#!/bin/bash

# sourcekit-bsp Dev Container Setup Script

SWIFTLINT_VERSION="0.60.0"
SWIFTFORMAT_VERSION="0.57.2"

set -e

echo "🚀 Setting up sourcekit-bsp development environment..."

# Update package lists
echo "📦 Updating package lists..."
sudo apt-get update

# Install essential tools
echo "🛠️  Installing essential tools..."
sudo apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    build-essential \
    libxml2-dev \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncurses5-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libffi-dev \
    liblzma-dev \
    lldb \
    lldb-18

# Install SwiftLint
echo "🧹 Installing SwiftLint..."
curl -L "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/SwiftLintBinary.artifactbundle.zip" -o /tmp/SwiftLintBinary.artifactbundle.zip
cd /tmp
unzip SwiftLintBinary.artifactbundle.zip
sudo cp SwiftLintBinary.artifactbundle/swiftlint-${SWIFTLINT_VERSION}-linux-gnu/bin/swiftlint_arm64 /usr/local/bin/swiftlint
rm -rf /tmp/SwiftLintBinary.artifactbundle.zip /tmp/SwiftLintBinary.artifactbundle

# Install SwiftFormat
echo "🎨 Installing SwiftFormat..."
curl -L "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat_linux.zip" -o /tmp/swiftformat.zip
unzip /tmp/swiftformat.zip -d /tmp
sudo cp /tmp/swiftformat_linux /usr/local/bin/swiftformat
sudo chmod +x /usr/local/bin/swiftformat
rm -f /tmp/swiftformat.zip /tmp/swiftformat

# Verify installations
echo "✅ Verifying installations..."
echo "Swift version:"
swift --version

echo "SwiftLint version:"
swiftlint version

echo "SwiftFormat version:" 
swiftformat --version

echo "Git version:"
git --version

# Setup Swift package
echo "📚 Setting up Swift package..."
cd /workspace

# Initialize package if needed
if [ ! -f "Package.swift" ]; then
    echo "⚠️  Package.swift not found, creating basic package..."
    swift package init --type executable
fi

# Resolve dependencies
echo "🔗 Resolving Swift package dependencies..."
swift package resolve

# Create useful aliases
echo "🔧 Setting up aliases..."
cat >> ~/.zshrc << 'EOF'

# sourcekit-bsp Development Aliases
alias swiftbuild='swift build'
alias swifttest='swift test'
alias swiftrun='swift run'
alias swiftclean='swift package clean'
alias swiftformat-check='swiftformat --lint .'
alias swiftformat-fix='swiftformat .'
alias swiftlint-check='swiftlint'
alias swiftlint-fix='swiftlint --fix'
alias lint='swiftlint && swiftformat --lint .'
alias format='swiftformat . && swiftlint --fix'

# BSP Development
alias bsp-debug='swift run sourcekit-bsp --debug'
alias bsp-build='swift build && echo "✅ Build complete!"'
alias bsp-test='swift test --parallel'

# Quick commands
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
EOF

# Create development scripts
echo "📝 Creating development scripts..."
mkdir -p /workspace/.devcontainer/scripts

cat > /workspace/.devcontainer/scripts/lint.sh << 'EOF'
#!/bin/bash
echo "🧹 Running SwiftLint..."
swiftlint

echo "🎨 Running SwiftFormat (check mode)..."
swiftformat --lint .

echo "✅ Linting complete!"
EOF

cat > /workspace/.devcontainer/scripts/format.sh << 'EOF'
#!/bin/bash
echo "🎨 Running SwiftFormat..."
swiftformat .

echo "🧹 Running SwiftLint (auto-fix)..."
swiftlint --fix

echo "✅ Formatting complete!"
EOF

cat > /workspace/.devcontainer/scripts/build-and-test.sh << 'EOF'
#!/bin/bash
echo "🏗️  Building project..."
swift build

echo "🧪 Running tests..."
swift test --parallel

echo "✅ Build and test complete!"
EOF

# Make scripts executable
chmod +x /workspace/.devcontainer/scripts/*.sh

echo ""
echo "🎉 Dev Container setup complete!"
echo ""
echo "📝 Available commands:"
echo "  • swift build              - Build the project"
echo "  • swift test              - Run tests" 
echo "  • swiftlint               - Run linting"
echo "  • swiftformat .           - Format code"
echo "  • bsp-debug              - Run BSP with debug logging"
echo "  • ./.devcontainer/scripts/lint.sh     - Run all linters"
echo "  • ./.devcontainer/scripts/format.sh   - Format all code"
echo ""
echo "🚀 Ready for development!"
