# Dual-Agent Workflow

## Overview

ProxLab is operated by two AI agents with complementary access scopes. Neither agent is redundant — they cover different layers of the infrastructure and collaborate via shared task state in GitHub Issues.

---

## The Two Agents

| | BUILDER | PROXLAB |
|---|---|---|
| **Host** | claude-agent (<mgmt-ip>) | claude-lxc (CT 22202, 10.10.0.50) |
| **Lives** | AZNET management network (outside lab) | Inside ProxLab VLAN 100 |
| **Access method** | QEMU guest agent, SSH, Proxmox API | AD/Kerberos, WinRM, Ansible SSH |
| **Auth** | root SSH + sshpass, SSHENV password | svc-claude-ro (read), svc-claude-rw (write, disabled by default) |
| **Typical work** | Provision VMs, run scripts, set NICs, clone templates, infrastructure builds | Query AD, run playbooks, check SIEM alerts, execute approved remediation |
| **Started via** | `~/start-claude2.sh` on claude-agent | `~/start-claude.sh` on claude-lxc |

---

## Communication Model

The agents do not talk directly. They communicate through GitHub Issues in the private `ralfaroAutomation/lab-tasks` repo. GH Issues is the single source of truth for pending and completed work — no MD files, no git syncs for task state.

```
GitHub Issues (private: ralfaroAutomation/lab-tasks)
              ↑ gh issue close / create / comment
              |
   BUILDER (claude-agent)      PROXLAB (claude-lxc)
   label: BUILDER              label: PROXLAB
              |                     |
              └─────────────────────┘
                both read/write issues
```

Each agent filters issues by its own label. Stage labels (`stage-5` … `stage-11`) sequence the work. Closed issues serve as the completed log.

---

## Task Format

Each task is a GitHub Issue in `ralfaroAutomation/lab-tasks`:

- **Title:** concise action — e.g. `DC-02: OOBE, domain join, promote as secondary DC`
- **Labels:** agent label (`BUILDER` or `PROXLAB`) + stage label (`stage-5`) + topic label if relevant (`networking`, `power-management`, etc.)
- **Body:** optional detail, commands, or acceptance criteria

Common commands:

```bash
# List your open tasks
gh issue list --repo ralfaroAutomation/lab-tasks --label BUILDER --state open

# Close a completed task
gh issue close <number> --repo ralfaroAutomation/lab-tasks

# Create a new task
gh issue create --repo ralfaroAutomation/lab-tasks \
  --label BUILDER,stage-5 --title "..." --body "..."

# Hand off to the other agent
gh issue create --repo ralfaroAutomation/lab-tasks \
  --label PROXLAB --title "..." --body "..."

# Leave a blocker note
gh issue comment <number> --repo ralfaroAutomation/lab-tasks --body "blocked: reason"
```

---

## Session Protocol

### Every session start
1. Open task queue is injected automatically by the startup script — no manual fetch needed
2. Pick the lowest open stage or highest priority issue

### During session
- Close issues as work completes: `gh issue close <number> --repo ralfaroAutomation/lab-tasks`
- Create new issues for discovered work — tag the right agent and stage
- Comment on an issue if blocked rather than leaving it silently open

### Every session end
No git push needed — GH Issues updates are live immediately.

---

## Access Boundaries

**BUILDER** can act when:
- A VM needs to be created, cloned, or reconfigured in Proxmox
- A script needs to run on a VM before AD/WinRM is wired up
- Network changes are needed at the hypervisor level

**PROXLAB** can act when:
- AD, DNS, DHCP queries are needed
- PowerShell should run on a domain VM via WinRM
- Ansible playbooks need to run against Linux VMs
- SIEM alerts need reading or responding to

**Escalation:** If BUILDER discovers a task that requires AD access, it creates a `PROXLAB`-labeled issue. If PROXLAB needs a VM reconfigured, it creates a `BUILDER`-labeled issue.

---

## svc-claude-rw Safety Rule

`svc-claude-rw` (write account) is **disabled by default** in AD. PROXLAB enables it only for the specific operation that requires write access, then disables it immediately. Every use is logged to `/var/log/claude-agent/actions.log`.

---

## Token Usage Optimization

Long-running lab sessions are expensive on context. Both agents follow the same discipline.

### headroom

[headroom](https://github.com/cytostack/headroom) wraps the Claude CLI and surfaces a live token counter in the terminal status bar. It makes context pressure visible before it becomes a problem — no more waiting for a warning to compact.

Wired into the BUILDER startup script:

```bash
headroom wrap /root/.local/bin/claude -- --remote-control
```

The PROXLAB agent should mirror this pattern in `~/start-claude.sh` once claude-lxc is set up.

### Startup context injection

Before Claude starts, `start-claude2.sh` runs `gh issue list` and prints the top open BUILDER tasks into the terminal. This seeds the session with task state without a tool call.

### Session rules

| Rule | Why |
|---|---|
| `/compact` at natural breakpoints | After a stage, after large file reads, before topic switch — don't wait for pressure |
| `/clear` between unrelated tasks | Stale context from a previous task inflates token count without value |
| Targeted reads only (`grep`, specific line ranges) | Wide `cat` of large files is the single biggest context drain |
| Use `gh issue list` for task state | Never read old MD task files — they are stale and no longer maintained |

---

## Setup Checklist for claude-lxc

Before PROXLAB agent is operational:

- [ ] Claude Code installed on claude-lxc: `npm install -g @anthropic-ai/claude-code`
- [ ] homelab repo cloned: `git clone https://github.com/ralfaroAutomation/homelab /home/projects/homelab`
- [ ] `~/start-claude.sh` created (same pattern as claude-agent but without `--remote-control` if headless)
- [ ] `/etc/krb5.conf` configured with CORP.LAB realm
- [ ] Keytabs pulled from DC-01: `/etc/krb5/svc-claude-ro.keytab`, `svc-claude-rw.keytab`
- [ ] SSH key from claude-lxc added to authorized_keys on all Linux VMs
- [ ] PROXLAB CLAUDE.md created at `/home/projects/homelab/claude/proxlab.CLAUDE.md` with lab-internal connection strings
