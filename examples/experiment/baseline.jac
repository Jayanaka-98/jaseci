"""Baseline: Single by llm() call with full skill text + tools.

Simulates the skill.md approach: one LLM invocation carries the full
skill instructions as a parameter. In the ReAct loop, the skill text
is in the conversation history for EVERY API call, growing the context.
"""

import from measure { setup, show_results }
import from mock_tools {
    get_os_info,
    get_listening_ports,
    get_firewall_status,
    run_security_audit,
    check_update_status,
    execute_command
}

glob SKILL_INSTRUCTIONS: str = """You are performing a host security healthcheck. Follow these steps IN ORDER:

STEP 1 — GATHER CONTEXT: Call get_os_info(), get_listening_ports(), get_firewall_status() to understand the system.

STEP 2 — SECURITY AUDIT: Call run_security_audit() to get the audit findings.

STEP 3 — VERSION CHECK: Call check_update_status() to check for updates.

STEP 4 — RISK ASSESSMENT: Based on the gathered context, determine the appropriate risk profile:
  - BALANCED: Home/workstation, firewall on, LAN-restricted access
  - HARDENED: VPS, deny-by-default firewall, key-only SSH
  - DEVELOPER: More local services allowed, still audited

STEP 5 — REMEDIATION PLAN: Based on the audit findings and risk profile, produce a remediation plan.
Each step must include: description, exact command, impact, rollback instructions, and whether it's critical.

STEP 6 — EXECUTE: For each critical remediation step, call execute_command() with the exact command.

STEP 7 — VERIFY: Call run_security_audit() again to verify the fixes.

Your final answer must be a structured summary with:
- System context (OS, ports, firewall status)
- Audit score before and after
- Risk profile chosen
- Remediation steps taken
- Final posture assessment""";

"""Perform a complete host security healthcheck following the skill instructions."""
def run_healthcheck(skill_instructions: str) -> str by llm(
    tools=[
        get_os_info,
        get_listening_ports,
        get_firewall_status,
        run_security_audit,
        check_update_status,
        execute_command
    ],
    max_react_iterations=20
);

sem run_healthcheck = "Follow the provided skill instructions step by step to perform a complete host security healthcheck. Call all required tools in order.";
sem run_healthcheck.skill_instructions = "The complete skill instructions describing every step to follow.";

with entry {
    setup();
    print("=== BASELINE: Single by llm() with skill text + tools ===\n");
}

glob success = True,
     result = "";

with entry {
    try {
        result = run_healthcheck(SKILL_INSTRUCTIONS);
        print(str(result)[:2000]);
    } except Exception as e {
        print(f"ERROR: {e}");
        success = False;
    }

    # Validate: did the LLM actually complete all steps?
    if success {
        r = str(result).lower();
        has_context = "os" in r or "darwin" in r or "system" in r;
        has_audit = "audit" in r or "score" in r or "finding" in r;
        has_risk = "balanced" in r or "hardened" in r or "developer" in r or "risk" in r;
        has_plan = "remediation" in r or "command" in r or "step" in r;
        success = has_context and has_audit and has_risk and has_plan;
        if not success {
            print("VALIDATION FAILED: output missing required sections");
        }
    }

    show_results("BASELINE (skill-in-prompt + tools)", success);
}
