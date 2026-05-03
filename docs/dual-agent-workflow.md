# Dual-Agent Workflow

## Overview

ProxLab is operated by two AI agents with complementary access scopes. Neither agent is redundant — they cover different layers of the infrastructure and collaborate via shared task state in the git repo.

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

The agents do not talk directly. They communicate through a dedicated task repo, kept separate from the documentation repo to avoid polluting the commit log:

```
GitHub (private: ralfaroAutomation/lab-tasks)
        ↑  push (on session end + cron 09:00/21:00)
        |
  /home/projects/lab-tasks/
  ├── pending-tasks.md     ← shared task inbox
  └── completed-tasks.md  ← shared done log
        |
        ↓  git pull (on session start)
GitHub (private: ralfaroAutomation/lab-tasks)
```

Documentation and scripts stay in `ralfaroAutomation/homelab` with a clean commit history. Task sync commits go only to `lab-tasks`. Each agent pulls on start, updates task files as work is done, and pushes on end. The cron on claude-agent (`/root/sync-tasks.sh`) also syncs at 09:00 and 21:00 as a safety net.

---

## Task Format

Every task in `pending-tasks.md` is tagged with which agent should execute it:

```markdown
- [ ] `[BUILDER]` ATK-01: rebuild with Kali 2026.1 ISO, static IP 10.10.3.30
- [ ] `[PROXLAB]` Validate WinRM against FS-01 via Kerberos (pywinrm)
```

When complete, the item moves to `completed-tasks.md`:

```markdown
- [x] `[BUILDER]` ATK-01 rebuilt — 2026-05-04
- [x] `[PROXLAB]` WinRM validated against FS-01 — 2026-05-05
```

---

## Session Protocol

### Every session start
1. `git pull --ff-only origin main` — pick up any work the other agent completed
2. Read `pending-tasks.md` — load your tagged tasks into context
3. Note any tasks the other agent just completed in `completed-tasks.md`

### During session
- Move tasks from pending → completed as they finish
- Add new tasks discovered during work (tag them correctly)
- Never delete a task — move it or leave it

### Every session end
1. `git add pending-tasks.md completed-tasks.md`
2. `git commit -m "chore: task state — <session summary>"`
3. `git push origin main`

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

**Escalation:** If BUILDER discovers a task that requires AD access (e.g., check if a user exists), it tags a task `[PROXLAB]` and commits. If PROXLAB needs a VM reconfigured (e.g., add a NIC), it tags a task `[BUILDER]` and commits.

---

## svc-claude-rw Safety Rule

`svc-claude-rw` (write account) is **disabled by default** in AD. PROXLAB enables it only for the specific operation that requires write access, then disables it immediately. Every use is logged to `/var/log/claude-agent/actions.log`.

---

## Setup Checklist for claude-lxc

Before PROXLAB agent is operational:

- [ ] Claude Code installed on claude-lxc: `npm install -g @anthropic-ai/claude-code`
- [ ] homelab repo cloned: `git clone https://github.com/ralfaroAutomation/homelab /home/projects/homelab`
- [ ] `~/start-claude.sh` created (same pattern as claude-agent but without `--remote-control` if headless)
- [ ] `/etc/krb5.conf` configured with CORP.LAB realm
- [ ] Keytabs pulled from DC-01: `/etc/krb5/svc-claude-ro.keytab`, `svc-claude-rw.keytab`
- [ ] SSH key from claude-lxc added to authorized_keys on all Linux VMs
- [ ] PROXLAB CLAUDE.md created at `/home/projects/homelab/CLAUDE-proxlab.md` with lab-internal connection strings
