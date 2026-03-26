"""Host Security Healthcheck - byLLM+OSP reimplementation of the healthcheck skill.

Demonstrates all 7 primitives from the ASPLOS-26 tutorial:
  - Generate: LLM recommends risk profile from system context
  - Extract:  LLM returns typed AuditReport, RemediationPlan, PostureReport
  - Invoke:   Tool functions call real system commands (uname, lsof, openclaw)
  - Pipe:     Walker carries state forward through the workflow graph
  - Route:    Graph topology defines the workflow stages
  - Loop:     Verification node loops back to PlanGeneration via RetryEdge
  - Spawn:    Entry block spawns the HealthChecker walker on the graph

The skill.md version is 246 lines of English prose that an LLM agent
interprets at runtime. This version compiles the same workflow into
a typed, graph-based program with enforced output schemas.
"""

import from typing { Optional }
import subprocess;

# ============================================================
# Structured types (Extract primitive - enforced output schemas)
# ============================================================

enum OS { LINUX, MACOS, WINDOWS }

enum Privilege { ROOT, USER }

enum RiskProfile {
    BALANCED,
    HARDENED,
    DEVELOPER,
    CUSTOM
}
sem RiskProfile.BALANCED = "Home/Workstation: firewall on, remote access restricted to LAN or tailnet";
sem RiskProfile.HARDENED = "VPS: deny-by-default firewall, key-only SSH, no root login, auto security updates";
sem RiskProfile.DEVELOPER = "Developer: more local services allowed, explicit exposure warnings, still audited";
sem RiskProfile.CUSTOM = "User-defined constraints";

enum Severity { CRITICAL, WARNING, INFO, PASS }

enum ExecutionChoice {
    GUIDED,
    PLAN_ONLY,
    CRITICAL_ONLY,
    EXPORT
}

obj SystemContext {
    has os: OS;
    has os_version: str;
    has privilege: Privilege;
    has access_path: str;
    has network_exposure: str;
    has disk_encrypted: bool;
    has auto_updates: bool;
    has backup_status: str;
}
sem SystemContext = "Host system context gathered from read-only checks";
sem SystemContext.access_path = "How the user connects: local console, SSH, RDP, tailnet";
sem SystemContext.network_exposure = "Public IP, reverse proxy, tunnel, or LAN-only";

obj AuditFinding {
    has severity: Severity;
    has category: str;
    has description: str;
    has remediation: str;
}

obj AuditReport {
    has findings: list[AuditFinding];
    has score: int;
    has summary: str;
}
sem AuditReport.score = "Overall security posture score from 1 (critical) to 10 (excellent)";

obj RemediationStep {
    has description: str;
    has command: str;
    has impact: str;
    has rollback: str;
    has is_critical: bool;
}

obj RemediationPlan {
    has target_profile: str;
    has current_summary: str;
    has gaps: list[str];
    has steps: list[RemediationStep];
    has risks: list[str];
}

obj PostureReport {
    has firewall_ok: bool;
    has open_ports: list[str];
    has access_verified: bool;
    has audit_passed: bool;
    has final_score: int;
    has deferred_items: list[str];
}

# ============================================================
# Tool functions (Invoke primitive - real system commands)
# ============================================================

"""Get OS type and version information."""
def get_os_info() -> str {
    result = subprocess.run(
        ["uname", "-a"],
        capture_output=True, text=True
    );
    return result.stdout.strip();
}

"""Get listening network ports."""
def get_listening_ports() -> str {
    result = subprocess.run(
        ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
        capture_output=True, text=True
    );
    return result.stdout.strip();
}

"""Get firewall status."""
def get_firewall_status() -> str {
    result = subprocess.run(
        ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"],
        capture_output=True, text=True
    );
    return result.stdout.strip();
}

"""Run the security audit and return raw output."""
def run_security_audit(deep: bool = False) -> str {
    cmd = ["openclaw", "security", "audit"];
    if deep {
        cmd.append("--deep");
    }
    result = subprocess.run(cmd, capture_output=True, text=True);
    return result.stdout.strip();
}

"""Check application update status."""
def check_update_status() -> str {
    result = subprocess.run(
        ["openclaw", "update", "status"],
        capture_output=True, text=True
    );
    return result.stdout.strip();
}

"""Execute a single remediation command and return its output."""
def execute_remediation(command: str) -> str {
    result = subprocess.run(
        command.split(),
        capture_output=True, text=True
    );
    return f"exit={result.returncode}\n{result.stdout}\n{result.stderr}";
}

# ============================================================
# byLLM functions (Generate + Extract primitives)
# ============================================================

"""Analyze raw system info and build a structured context."""
def analyze_system_context(
    os_info: str,
    ports: str,
    firewall: str
) -> SystemContext by llm();
sem analyze_system_context = """Analyze the raw system information and produce a structured SystemContext.
Infer OS type, version, privilege level, network exposure, and security posture
from the command outputs provided.""";

"""Analyze raw audit output into structured findings."""
def analyze_audit_results(raw_audit: str) -> AuditReport by llm();
sem analyze_audit_results = """Parse the security audit output into structured findings.
Classify each finding by severity (CRITICAL, WARNING, INFO, PASS).
Score overall posture from 1 (critical risk) to 10 (excellent).""";

"""Recommend a risk profile based on system context."""
def recommend_risk_profile(context: SystemContext) -> RiskProfile by llm();
sem recommend_risk_profile = """Based on the system context, recommend the most appropriate risk profile.
Most home/workstation users should get BALANCED.
Servers with public IPs should get HARDENED.
Machines with many dev services should get DEVELOPER.""";

"""Generate a remediation plan based on gaps between current state and target."""
def generate_remediation_plan(
    audit: AuditReport,
    context: SystemContext,
    target_profile: str
) -> RemediationPlan by llm();
sem generate_remediation_plan = """Create a step-by-step remediation plan.
Each step must include the exact command, its impact, and rollback instructions.
Mark steps that address CRITICAL findings as is_critical=true.
Include access-preservation strategy and potential lockout risks.""";

"""Generate final posture report after remediation."""
def assess_final_posture(
    firewall: str,
    ports: str,
    new_audit: AuditReport
) -> PostureReport by llm();
sem assess_final_posture = """Produce a final posture report.
Compare pre and post remediation state.
List any deferred items that still need attention.""";

# ============================================================
# OSP: Graph nodes (workflow stages)
# ============================================================

node ContextGathering {
    has description: str = "Gather system context via read-only checks: OS, ports, firewall, encryption";
}

node SecurityAudit {
    has description: str = "Run openclaw security audit --deep and analyze findings";
}

node VersionCheck {
    has description: str = "Check openclaw update status and report channel/version";
}

node RiskAssessment {
    has description: str = "Determine target risk profile based on system context";
}

node PlanGeneration {
    has description: str = "Generate remediation plan with exact commands and rollback steps";
}

node Execution {
    has description: str = "Execute approved remediation steps with per-step confirmation";
}

node Verification {
    has description: str = "Re-run audit, verify fixes, produce final posture report";
}

# Edge for the self-correction loop (Verification -> PlanGeneration)
edge RetryEdge {
    has reason: str = "Re-remediate: audit score below threshold after fix attempt";
}

# ============================================================
# OSP: Walker (the agent traversing the workflow graph)
# ============================================================

walker HealthChecker {
    # Configuration
    has max_retries: int = 2;
    has score_threshold: int = 7;
    has execution_choice: ExecutionChoice = ExecutionChoice.PLAN_ONLY;

    # Accumulated state (Pipe primitive - output flows forward)
    has context: SystemContext | None = None;
    has audit: AuditReport | None = None;
    has plan: RemediationPlan | None = None;
    has report: PostureReport | None = None;
    has target_risk: RiskProfile = RiskProfile.BALANCED;
    has update_status: str = "";
    has retry_count: int = 0;

    # Step 1: Gather context (Invoke - call system tools)
    can gather with ContextGathering entry {
        os_info = get_os_info();
        ports = get_listening_ports();
        firewall = get_firewall_status();
        # Extract: LLM returns typed SystemContext from raw strings
        self.context = analyze_system_context(os_info, ports, firewall);
        print(f"[1/7] System: {self.context.os.name} {self.context.os_version}");
        print(f"       Access: {self.context.access_path}");
        print(f"       Encrypted: {self.context.disk_encrypted}");
        visit [-->];
    }

    # Step 2: Security audit (Invoke + Extract)
    can audit_step with SecurityAudit entry {
        raw = run_security_audit(deep=True);
        self.audit = analyze_audit_results(raw);
        print(f"[2/7] Audit score: {self.audit.score}/10 ({len(self.audit.findings)} findings)");
        for f in self.audit.findings {
            if f.severity == Severity.CRITICAL or f.severity == Severity.WARNING {
                print(f"       [{f.severity.name}] {f.category}: {f.description}");
            }
        }
        visit [-->];
    }

    # Step 3: Version check (Invoke)
    can version with VersionCheck entry {
        self.update_status = check_update_status();
        print(f"[3/7] {self.update_status}");
        visit [-->];
    }

    # Step 4: Risk assessment (Generate - LLM picks profile)
    can assess with RiskAssessment entry {
        self.target_risk = recommend_risk_profile(self.context);
        print(f"[4/7] Recommended profile: {self.target_risk.name}");
        visit [-->];
    }

    # Step 5: Plan generation (Extract - structured remediation plan)
    can plan_step with PlanGeneration entry {
        self.plan = generate_remediation_plan(
            self.audit, self.context, self.target_risk.name
        );
        print(f"[5/7] Plan: {len(self.plan.steps)} steps targeting {self.plan.target_profile}");
        for (i, step) in enumerate(self.plan.steps) {
            marker = "!!" if step.is_critical else "  ";
            print(f"  {marker} {i+1}. {step.description}");
            print(f"         $ {step.command}");
        }
        visit [-->];
    }

    # Step 6: Execute (Invoke with confirmation gate)
    can execute with Execution entry {
        if self.execution_choice == ExecutionChoice.PLAN_ONLY {
            print("[6/7] Plan-only mode - skipping execution");
        } elif self.execution_choice == ExecutionChoice.EXPORT {
            print("[6/7] Exported commands:");
            for step in self.plan.steps {
                print(f"  {step.command}");
            }
        } else {
            for step in self.plan.steps {
                if self.execution_choice == ExecutionChoice.CRITICAL_ONLY and not step.is_critical {
                    continue;
                }
                print(f"  Executing: {step.command}");
                print(f"  Impact: {step.impact} | Rollback: {step.rollback}");
                output = execute_remediation(step.command);
                print(f"  Result: {output}");
            }
        }
        visit [-->];
    }

    # Step 7: Verify (Loop primitive - self-correction cycle)
    can verify with Verification entry {
        firewall = get_firewall_status();
        ports = get_listening_ports();
        raw = run_security_audit(deep=True);
        new_audit = analyze_audit_results(raw);

        # Loop: if score still below threshold and retries remain,
        # follow the RetryEdge back to PlanGeneration for another pass
        if new_audit.score < self.score_threshold and self.retry_count < self.max_retries {
            self.retry_count += 1;
            self.audit = new_audit;
            print(f"[7/7] Score {new_audit.score}/10 < threshold {self.score_threshold} - retry {self.retry_count}/{self.max_retries}");
            visit [-->](`?PlanGeneration);
            return;
        }

        # Final report
        self.report = assess_final_posture(firewall, ports, new_audit);
        print(f"[7/7] Final posture: {self.report.final_score}/10");
        print(f"       Firewall OK: {self.report.firewall_ok}");
        print(f"       Audit passed: {self.report.audit_passed}");
        if self.report.deferred_items {
            print("       Deferred:");
            for item in self.report.deferred_items {
                print(f"         - {item}");
            }
        }
    }
}

# ============================================================
# Entry: Build workflow graph and spawn the agent
# ============================================================

with entry {
    # Build the linear workflow pipeline
    ctx_node = ContextGathering();
    audit_node = SecurityAudit();
    ver_node = VersionCheck();
    risk_node = RiskAssessment();
    plan_node = PlanGeneration();
    exec_node = Execution();
    verify_node = Verification();

    root ++> ctx_node;
    ctx_node ++> audit_node;
    audit_node ++> ver_node;
    ver_node ++> risk_node;
    risk_node ++> plan_node;
    plan_node ++> exec_node;
    exec_node ++> verify_node;

    # Self-correction loop: Verification -> PlanGeneration
    verify_node +>:RetryEdge():+> plan_node;

    # Spawn the healthcheck agent
    checker = root spawn HealthChecker(
        execution_choice=ExecutionChoice.GUIDED,
        max_retries=2,
        score_threshold=7
    );

    # Final summary
    if checker.report {
        print("\n=== HEALTHCHECK COMPLETE ===");
        print(f"Score: {checker.report.final_score}/10");
        print(f"Retries used: {checker.retry_count}/{checker.max_retries}");
    }
}
