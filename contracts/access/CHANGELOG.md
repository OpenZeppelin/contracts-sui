<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to the Access package will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## Unreleased

### Added

- `two_step_transfer` module that wraps a `key + store` capability behind a request/approve flow.
- `delayed_transfer` module that enforces configurable, clock-based delays before transferring or unwrapping a capability.
