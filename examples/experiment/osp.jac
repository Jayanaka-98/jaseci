"""OSP + byLLM: Graph-based approach with scoped LLM calls.

Each by llm() call sends ONLY what it needs — function signature,
sem string, parameter values, and return type schema. No skill text.
No accumulated conversation history between calls.
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

# ── Structured types (enforced output schemas) ──────────────
enum OS { LINUX, MACOS, WINDOWS }
enum Privilege { ROOT, USER }
enum RiskProfile { BALANCED, HARDENED, DEVELOPER }
sem RiskProfile.BALANCED = "Home/Workstation: firewall on, remote access restricted to LAN";
sem RiskProfile.HARDENED = "VPS: deny-by-default firewall, key-only SSH, no root login";
sem RiskProfile.DEVELOPER = "Developer: more local services allowed, explicit exposure warnings";

enum Severity { CRITICAL, WARNING, INFO, PASS }

obj SystemContext {
    has os: OS,
        os_version: str,
        privilege: Privilege,
        network_exposure: str,
        disk_encrypted: bool,
        auto_updates: bool;
}

sem SystemContext = "Host system context from read-only checks";
sem SystemContext.network_exposure = "Public IP, reverse proxy, tunnel, or LAN-only";

obj AuditFinding {
    has severity: Severity,
        category: str,
        description: str,
        remediation: str;
}

obj AuditReport {
    has findings: list[AuditFinding],
        score: int,
        summary: str;
}

sem AuditReport.score = "Security posture score from 1 (critical) to 10 (excellent)";

obj RemediationStep {
    has description: str,
        command: str,
        impact: str,
        rollback: str,
        is_critical: bool;
}

obj RemediationPlan {
    has target_profile: str,
        gaps: list[str],
        steps: list[RemediationStep];
}

obj PostureReport {
    has firewall_ok: bool,
        audit_passed: bool,
        final_score: int,
        deferred_items: list[str];
}

# ── Scoped byLLM functions (no skill text, just typed contracts) ──
"""Analyze raw system info into structured context."""
def analyze_context(os_info: str, ports: str, firewall: str) -> SystemContext by llm();

sem analyze_context = "Infer OS type, version, privilege, and network exposure from raw command outputs.";

"""Parse audit output into structured findings with severity."""
def analyze_audit(raw_audit: str) -> AuditReport by llm();

sem analyze_audit = "Classify each finding by severity. Score posture 1-10.";

"""Recommend risk profile based on system context."""
def recommend_profile(context: SystemContext) -> RiskProfile by llm();

sem recommend_profile = "Home/workstation users get BALANCED. Public servers get HARDENED. Dev machines get DEVELOPER.";

"""Generate remediation plan from audit gaps."""
def make_plan(
    audit: AuditReport, context: SystemContext, profile: str
) -> RemediationPlan by llm();

sem make_plan = "Each step needs: command, impact, rollback. Mark CRITICAL findings as is_critical=true.";

"""Assess final posture after remediation."""
def assess_posture(new_audit: AuditReport) -> PostureReport by llm();

sem assess_posture = "Produce final posture report. List deferred items.";

# ── Graph nodes ─────────────────────────────────────────────
node GatherContext {
    has description: str = "Gather system context via read-only checks";
}

node RunAudit {
    has description: str = "Run security audit and analyze findings";
}

node CheckVersion {
    has description: str = "Check update status";
}

node AssessRisk {
    has description: str = "Determine target risk profile";
}

node GeneratePlan {
    has description: str = "Generate remediation plan";
}

node Execute {
    has description: str = "Execute critical remediation steps";
}

node Verify {
    has description: str = "Re-audit and produce final posture report";
}

# ── Walker ──────────────────────────────────────────────────
walker HealthChecker {
    has context: SystemContext | None = None,
        audit: AuditReport | None = None,
        plan: RemediationPlan | None = None,
        posture: PostureReport | None = None,
        profile: RiskProfile = RiskProfile.BALANCED,
        update_info: str = "";

    can step_gather with GatherContext entry {
        os_info = get_os_info();
        ports = get_listening_ports();
        fw = get_firewall_status();
        self.context = analyze_context(os_info, ports, fw);
        print(
            f"[1/7] {self.context.os.name} — exposure: {self.context.network_exposure}"
        );
        visit [-->];
    }

    can step_audit with RunAudit entry {
        raw = run_security_audit();
        self.audit = analyze_audit(raw);
        print(
            f"[2/7] Audit score: {self.audit.score}/10 ({len(
                self.audit.findings
            )} findings)"
        );
        visit [-->];
    }

    can step_version with CheckVersion entry {
        self.update_info = check_update_status();
        print(f"[3/7] {self.update_info}");
        visit [-->];
    }

    can step_risk with AssessRisk entry {
        self.profile = recommend_profile(self.context);
        print(f"[4/7] Profile: {self.profile.name}");
        visit [-->];
    }

    can step_plan with GeneratePlan entry {
        self.plan = make_plan(self.audit, self.context, self.profile.name);
        print(f"[5/7] Plan: {len(self.plan.steps)} steps");
        for (i, s) in enumerate(self.plan.steps) {
            print(f"  {i + 1}. {'!!' if s.is_critical else '  '} {s.description}");
        }
        visit [-->];
    }

    can step_execute with Execute entry {
        for s in self.plan.steps {
            if s.is_critical {
                output = execute_command(s.command);
                print(f"[6/7] Executed: {s.command}");
            }
        }
        visit [-->];
    }

    can step_verify with Verify entry {
        raw = run_security_audit();
        new_audit = analyze_audit(raw);
        self.posture = assess_posture(new_audit);
        print(f"[7/7] Final score: {self.posture.final_score}/10");
    }
}

# ── Entry ───────────────────────────────────────────────────
with entry {
    setup();
    print("=== OSP + byLLM: Graph-based scoped calls ===\n");
}

glob success = True;

with entry {
    try {
        # Build workflow graph
        n1 = GatherContext();
        n2 = RunAudit();
        n3 = CheckVersion();
        n4 = AssessRisk();
        n5 = GeneratePlan();
        n6 = Execute();
        n7 = Verify();

        root ++> n1 ++> n2 ++> n3 ++> n4 ++> n5 ++> n6 ++> n7;

        # Spawn walker on first node
        checker = n1 spawn HealthChecker();

        # Validate: did the walker complete all steps?
        if checker.posture {
            print(
                f"\nFinal posture: score={checker.posture.final_score}, passed={checker.posture.audit_passed}"
            );
        }
        # Check all structured outputs were produced
        has_context = checker.context is not None;
        has_audit = checker.audit is not None;
        has_plan = checker.plan is not None;
        has_posture = checker.posture is not None;
        success = has_context and has_audit and has_plan and has_posture;
        if not success {
            missing: list = [];
            if not has_context {
                missing.append("context");
            }
            if not has_audit {
                missing.append("audit");
            }
            if not has_plan {
                missing.append("plan");
            }
            if not has_posture {
                missing.append("posture");
            }
            print(f"VALIDATION FAILED: missing {missing}");
        }
    } except Exception as e {
        print(f"ERROR: {e}");
        success = False;
    }

    show_results("OSP + byLLM (scoped calls)", success);
}
