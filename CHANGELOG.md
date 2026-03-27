# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Community health files: CONTRIBUTING.md, CODE_OF_CONDUCT.md, issue templates, PR template, CODEOWNERS
- SECURITY.md with vulnerability reporting policy and security model documentation
- AGENTS.md for AI agent contribution guidelines
- CHANGELOG.md following Keep a Changelog format
- `verification.oracle.security_command` config key for security scans in regress phase
- .gitignore for Python bytecode, runtime artifacts, and IDE files

### Changed
- Moved whitepaper, HOWTO, todo files, papers, and research artifacts into docs/ hierarchy
- Cleaned up repo root to <20 visible items
- Removed tracked __pycache__ files

## [1.0.0] - 2026-03-17

### Added
- 6-phase autonomous improvement loop (Backlog, Ideate, Triage, Execute, Polish, Regress)
- UAT gate with fresh-agent adversarial testing
- Discussion Manager for multi-AI structured debates
- Spec surface coverage tracking and coverage matrix
- Drift metrics and threshold enforcement
- Multi-model tribunal for PR reviews
- Drain mode for PR backpressure management
- Issue register for discussion convergence tracking
- Blind opening round for anti-sycophancy in discussions
- GitHub Issues ticketing integration
- CodeRabbit review bot integration
- PR Manager for automated PR lifecycle
- Python CLI and Web API example configs
- Whitepaper with academic citations
- Interactive init wizard for project onboarding
