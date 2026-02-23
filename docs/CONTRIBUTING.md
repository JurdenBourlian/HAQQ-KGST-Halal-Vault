# Contributing to HAQQ-KGST-Halal-Vault

We welcome contributions from the community! Whether you're fixing bugs, improving documentation, or proposing new features, your help is appreciated.

## Code of Conduct
By participating in this project, you agree to abide by our Code of Conduct. Please be respectful, inclusive, and constructive in all interactions.

## How to Contribute

### 1. Reporting Issues
**Bug Reports:**
- Use the GitHub Issues tracker
- Include clear steps to reproduce
- Specify environment (OS, Node version, Foundry version)
- Include relevant code snippets and error messages

**Feature Requests:**
- Clearly describe the feature and its use case
- Explain why it would be valuable to the project
- If possible, suggest implementation approach

### 2. Pull Requests
**Process:**
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to your branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

**PR Guidelines:**
- Link to any related issues
- Update documentation if needed
- Ensure all tests pass (`forge test`)
- Add new tests for new functionality
- Follow existing code style
- Keep PRs focused on a single change

### 3. Documentation
Documentation improvements are always welcome:
- Fix typos or unclear explanations
- Add examples
- Translate to other languages
- Improve diagrams

### 4. Testing
Help improve test coverage:
- Write new unit tests
- Add fuzzing test cases
- Create integration test scenarios
- Test on testnets

## Development Setup

### Prerequisites
- [Foundry](https://getfoundry.sh/)
- Git
- Basic knowledge of Solidity and DeFi

### Installation
```bash
# Clone your fork
git clone https://github.com/haqq-kgst.git
cd halal-vault
# Add upstream remote
git remote add upstream https://github.com/haqq-kgst.git
# Install dependencies
forge install
# Build
forge build
```

### Running Tests
```bash
# Run all tests
forge test
# Run with verbosity
forge test -vv
# Run specific test
forge test --match-test testDeposit
# Run with gas reporting
forge test --gas-report
```

### Code Style Guidelines

**Solidity**
- Follow Solhint recommended rules
- Use NatSpec comments for all public functions
- Use 4 spaces for indentation
- Maximum line length: 120 characters
- Order of functions: constructor, receive/fallback, external, public, internal, private
- Order of variables: constants, immutables, state variables, events, errors

**Naming Conventions**
- Contracts: PascalCase
- Functions: camelCase
- Variables: camelCase (public), _camelCase (internal/private)
- Constants: UPPER_CASE_WITH_UNDERSCORES
- Events: PascalCase (past tense, e.g., Deposited)
- Errors: PascalCase (e.g., InsufficientBalance)

### Documentation
All public functions must have NatSpec comments:
```solidity
/**
 * @notice Deposits KGST and mints hvKGST shares
 * @dev Shariah compliance is checked before deposit
 * @param assets Amount of KGST to deposit
 * @param receiver Address to receive the hvKGST shares
 * @return shares Amount of hvKGST minted
 */
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
```

### Testing Guidelines

**Test Structure**
- Place tests in test/ directory
- Name test files with .t.sol suffix
- Group related tests in contract files
- Use meaningful test names

**Test Coverage Goals**
- Core contracts: 100% line coverage
- Strategies: 90%+ line coverage
- Integration tests: Cover main user flows
- Fuzz tests: Critical math operations
- Invariant tests: Protocol invariants

### Branch Strategy
- `main` - Production-ready code
- `develop` - Integration branch for features
- `feature/*` - New features
- `bugfix/*` - Bug fixes
- `release/*` - Release preparation

## Community
- **Website:** haqq-kgst.network
- **Email:** info@haqq-kgst.network

## License
By contributing, you agree that your contributions will be licensed under the MIT License.