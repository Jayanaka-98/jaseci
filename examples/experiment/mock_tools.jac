"""Shared mock tools for the healthcheck experiment.

Both baseline and OSP approaches use these same tools.
They return realistic static data so the LLM processes
meaningful content without needing real system access.
"""

"""Get OS type and version information (uname -a)."""
def get_os_info -> str {
    return "Darwin MacBook-Pro.local 24.3.0 Darwin Kernel Version 24.3.0: Thu Jan 2 20:24:16 PST 2025; root:xnu-11215.81.4~3/RELEASE_ARM64_T6000 arm64";
}

"""Get listening network ports (lsof -nP -iTCP -sTCP:LISTEN)."""
def get_listening_ports -> str {
    return """COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
rapportd    443   user    4u  IPv4 0xabc123      0t0  TCP *:49152 (LISTEN)
rapportd    443   user    5u  IPv6 0xabc124      0t0  TCP *:49152 (LISTEN)
ControlCe   449   user    7u  IPv4 0xdef456      0t0  TCP *:7000 (LISTEN)
ControlCe   449   user    8u  IPv6 0xdef457      0t0  TCP *:7000 (LISTEN)
postgres   1234   user    5u  IPv4 0x789abc      0t0  TCP localhost:5432 (LISTEN)
node       5678   user   23u  IPv4 0x321def      0t0  TCP *:3000 (LISTEN)
redis-ser  2345   user    6u  IPv4 0x654ghi      0t0  TCP localhost:6379 (LISTEN)
Python     8901   user    4u  IPv4 0x987jkl      0t0  TCP *:8000 (LISTEN)""";
}

"""Get macOS firewall status."""
def get_firewall_status -> str {
    return "Firewall is disabled. (State = 0)";
}

"""Run security audit (openclaw security audit --deep)."""
def run_security_audit -> str {
    return """OpenClaw Security Audit (deep mode)
=====================================
[CRITICAL] File permissions: ~/.openclaw/credentials.json is world-readable (mode 644)
[CRITICAL] Gateway bind: listening on 0.0.0.0:3000 (exposed to all interfaces)
[WARNING]  Browser control: enabled without 2FA on linked accounts
[WARNING]  API keys: 2 keys stored in plaintext in ~/.openclaw/config.json
[WARNING]  Session tokens: stored without encryption at rest
[INFO]     Plugin versions: all up to date
[INFO]     TLS: enabled for gateway connections
[PASS]     Sandbox: enabled for all agent operations
[PASS]     Disk quota: within limits

Score: 4/10 — Critical issues found. Run `openclaw security audit --fix` for safe defaults.""";
}

"""Check application update status (openclaw update status)."""
def check_update_status -> str {
    return "OpenClaw v2.4.1 (stable channel). Update available: v2.5.0 (security fixes, released 2026-03-20).";
}

"""Execute a remediation command. Returns simulated output."""
def execute_command(command: str) -> str {
    return f"$ {command}\nOK — command completed successfully (exit code 0)";
}
