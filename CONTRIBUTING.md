# Contributing to sourcekit-bsp

Thank you for your interest in contributing to sourcekit-bsp! This document provides guidelines and information for contributors.

## Code of Conduct

This project adheres to a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How to Contribute

### Reporting Bugs

1. **Check existing issues** first to avoid duplicates
2. **Use the bug report template** when creating new issues
3. **Provide detailed information** including:
   - Steps to reproduce the issue
   - Expected vs actual behavior
   - Environment details (macOS version, Xcode version, etc.)
   - Relevant log output

### Suggesting Features

1. **Check existing feature requests** to avoid duplicates
2. **Use the feature request template**
3. **Describe the problem** you're trying to solve
4. **Propose a solution** with implementation details if possible

### Contributing Code

#### Prerequisites

- macOS 12.0 or later
- Xcode 14.0 or later
- Swift 6.1 or later
- Familiarity with Build Server Protocol (BSP)

#### Development Setup

1. **Fork and clone** the repository:
   ```bash
   git clone https://github.com/yourusername/sourcekit-bsp.git
   cd sourcekit-bsp
   ```

2. **Install dependencies**:
   ```bash
   swift package resolve
   ```

3. **Build the project**:
   ```bash
   swift build
   ```

4. **Run tests**:
   ```bash
   swift test
   ```

#### Making Changes

1. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the coding standards below

3. **Add tests** for new functionality

4. **Ensure all tests pass**:
   ```bash
   swift test
   ```

5. **Run code quality checks**:
   ```bash
   mint bootstrap
   mint run swiftlint --strict
   mint run swiftformat . --lint
   ```

6. **Commit your changes** with clear, descriptive messages:
   ```bash
   git commit -m "Add feature: brief description of changes"
   ```

7. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

8. **Create a pull request** using the PR template

## Coding Standards

### Swift Style Guide

We follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/) and use SwiftLint for enforcement.

#### Key Points:

- **Naming**: Use clear, descriptive names
- **Access Control**: Use the most restrictive access level possible
- **Documentation**: Document all public APIs with triple-slash comments
- **Error Handling**: Use proper Swift error handling, avoid force unwrapping
- **Concurrency**: Use Swift's modern concurrency features (async/await, actors)

#### Example:

```swift
/// Manages the build server context for an Xcode project
public actor BuildServerContext {
    private let projectURL: URL
    private var buildSettings: [BuildSettings]?
    
    /// Initializes a new build server context
    /// - Parameter projectURL: The URL of the Xcode project or workspace
    public init(projectURL: URL) {
        self.projectURL = projectURL
    }
    
    /// Loads the project configuration and build settings
    /// - Throws: `BuildServerError` if the project cannot be loaded
    public func loadProject() async throws {
        // Implementation...
    }
}
```

### Architecture Guidelines

1. **Separation of Concerns**: Keep BSP protocol, JSON-RPC, and Xcode integration separate
2. **Thread Safety**: Use actors for shared mutable state
3. **Error Handling**: Define specific error types, avoid generic errors
4. **Testing**: Write unit tests for all public APIs
5. **Documentation**: Document complex algorithms and protocols

### Git Commit Messages

Follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
type(scope): description

[optional body]

[optional footer]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

Examples:
```
feat(bsp): add support for build target dependencies

fix(jsonrpc): handle malformed requests gracefully

docs(readme): update installation instructions
```

## Testing

### Unit Tests

- Write tests for all new functionality
- Maintain test coverage above 80%
- Use descriptive test names that explain what is being tested
- Follow the Arrange-Act-Assert pattern

### Integration Tests

- Test BSP protocol compliance
- Test Xcode integration with real projects
- Test error scenarios and edge cases

### Running Tests

```bash
# Run all tests
swift test

# Run specific test
swift test --filter TestClassName.testMethodName

# Run with coverage
swift test --enable-code-coverage
```

## Documentation

### Code Documentation

- Document all public APIs with triple-slash comments
- Include parameter descriptions and return value information
- Add usage examples for complex APIs
- Document thrown errors

### Architecture Documentation

- Update architecture diagrams for significant changes
- Document design decisions in ADRs (Architecture Decision Records)
- Keep the README up to date with new features

## Review Process

### Before Submitting

- [ ] Code follows style guidelines
- [ ] All tests pass
- [ ] Documentation is updated
- [ ] Commit messages follow conventions
- [ ] PR description explains the changes

### Review Criteria

Pull requests are reviewed for:

1. **Correctness**: Does the code work as intended?
2. **Design**: Is the code well-designed and fits the architecture?
3. **Functionality**: Does it fulfill the requirements?
4. **Complexity**: Is the code as simple as possible?
5. **Tests**: Are there appropriate tests?
6. **Naming**: Are names clear and descriptive?
7. **Comments**: Are comments clear and useful?
8. **Documentation**: Is documentation updated?

### Review Timeline

- Small changes: 1-2 days
- Medium changes: 3-5 days
- Large changes: 1-2 weeks

## Release Process

1. Version bumps follow [Semantic Versioning](https://semver.org/)
2. Releases are created from the `main` branch
3. Release notes are auto-generated from commit messages
4. Binaries are automatically built and uploaded via GitHub Actions

## Getting Help

- **Discussions**: Use GitHub Discussions for questions
- **Issues**: Create issues for bugs and feature requests
- **Discord**: Join our community Discord (link in README)

## Recognition

Contributors are recognized in:
- README acknowledgments
- Release notes
- GitHub contributors page

Thank you for contributing to sourcekit-bsp!