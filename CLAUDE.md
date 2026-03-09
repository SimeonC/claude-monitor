# Claude Code Instructions

## Testing

Always run tests before building with `install.sh`. Run this command without asking for permission:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

(`swift test` alone fails because the active developer directory is CommandLineTools, not Xcode.)

## Building

Always use `bash install.sh` to build the project. Never invoke `swiftc` directly. Run this command without asking for permission.
