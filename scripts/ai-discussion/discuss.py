#!/usr/bin/env python3
"""
Multi-AI Discussion Orchestrator
================================
Runs structured debates between AI CLI tools (Gemini, Codex, Claude, etc.).
Turn-by-turn discussion with convergence detection.

Supports two modes:

  FULL-AUTO: Run the entire debate in one shot (CLI-only models).
    python discuss.py "topic" --models gemini codex

  STEP-BY-STEP: Orchestrated by an external moderator (e.g. Claude Code
  subagent) that can mix CLI calls with subagent calls for isolation.
    python discuss.py "topic" --models gemini codex claude --create-only
    python discuss.py --resume X --run-turn gemini
    python discuss.py --resume X --run-turn codex
    python discuss.py --resume X --get-prompt claude   # stdout
    echo "$response" | python discuss.py --resume X --add-response claude
    python discuss.py --resume X --status
    echo '{"conclusion":"agreed",...}' | python discuss.py --resume X --save-report

The conversation is saved to a JSON file after every turn, so it can be
resumed if interrupted.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONVO_DIR = Path(__file__).parent / "conversations"
REPO_ROOT = Path(__file__).parent.parent.parent

# How each CLI is invoked. Adjust if your installation differs.
MODEL_CONFIGS = {
    "claude": {
        "display_name": "Claude",
        "cmd": ["claude", "-p"],
        "prompt_mode": "arg",
        "timeout": 300,
        "env_unset": ["CLAUDECODE"],  # avoid nested-session error
    },
    "gemini": {
        "display_name": "Gemini",
        # --approval-mode plan: read-only mode — Gemini can search and read
        #   files but cannot write, execute, or make any mutations.
        # --include-directories: adds repo root to Gemini's workspace so it
        #   can search and read source files during the debate.
        "cmd": ["gemini", "--approval-mode", "plan",
                "--include-directories", str(REPO_ROOT), "-p"],
        "prompt_mode": "arg",
        "timeout": 300,
        "env_unset": [],
    },
    "codex": {
        "display_name": "Codex",
        "cmd": ["codex", "exec"],
        "prompt_mode": "arg",
        "timeout": 300,
        "env_unset": [],
    },
}

DEFAULT_DEBATERS = ["gemini", "codex"]

# ---------------------------------------------------------------------------
# Prompt templates
# ---------------------------------------------------------------------------

SYSTEM_PREAMBLE = """\
You are {display_name}, participating in a structured multi-AI discussion.

RULES:
- Engage substantively with SPECIFIC arguments from other participants.
- Explicitly state where you agree AND where you disagree.
- Change your mind when presented with better arguments -- do NOT be stubborn.
- Genuine, well-reasoned disagreement is MORE valuable than premature consensus.
- Be concise and actionable (under {max_words} words of discussion).
- If you have file tools, READ the codebase to ground claims in actual code.
  Do NOT make assumptions about what exists -- verify them.

REQUIRED FORMAT -- you MUST end every response with this exact structure:
---
STANCE: <your main position in one sentence>
AGREEMENTS: <comma-separated points you agree with, or "none yet">
DISAGREEMENTS: <comma-separated points you still disagree with, or "none">
ISSUES: <new issues you want to raise for the group, or "none">
RESOLVED: <issue IDs from previous rounds that you consider resolved, or "none">
"""

FIRST_TURN = """\
{preamble}
=== TOPIC ===
{topic}
{context}{codebase_section}
Participants: {participants}

You are speaking {order} in round 1. Provide your initial analysis and position.
What are the key considerations? What would you recommend and why?
"""

FOLLOW_TURN = """\
{preamble}
=== TOPIC ===
{topic}
{codebase_section}
=== CONVERSATION SO FAR ===
{history}
{issue_register_section}
This is round {round_num} of {max_rounds}.{urgency}

Respond to the specific points raised. Where do you agree? Where do you push back?
If someone changed your mind, say so explicitly.
"""

URGENCY_PENULTIMATE = """
Note: One more round after this. Start converging on actionable conclusions."""

URGENCY_FINAL = """
FINAL ROUND. Focus on:
1. State your final position clearly.
2. Acknowledge where others changed your mind.
3. Document remaining disagreements honestly.
The goal is a useful synthesis, NOT forced consensus."""

KILL_GATE = """
KILL GATE (design mode): Before your analysis, you MUST include a section:
KILL_ARGUMENT: <Give your strongest argument for why this should NOT be built. Be genuine — if you can't think of one, say "No strong kill argument.">
"""

RATIFY_PROMPT = """\
You are {display_name}, a participant in a structured multi-AI discussion.

=== TOPIC ===
{topic}

=== DEBATE SUMMARY (after {num_rounds} rounds) ===

POINTS OF AGREEMENT reached during the debate:
{agreed_points}

REMAINING FRICTION POINTS:
{friction_points}

=== RATIFICATION ROUND ===
The debate is complete. Your task now is to ratify or object to the consolidated design.

1. State whether you RATIFY this design (yes / no / conditional)
2. For each friction point you still contest, propose a concrete resolution
3. Answer any open questions you have a strong position on

Be concise (under {max_words} words of discussion).

REQUIRED FORMAT -- end your response with:
---
RATIFIES: yes | no | conditional
OBJECTIONS: <specific remaining objections, or "none">
RESOLUTIONS: <concrete answers to open questions, or "none">
"""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ORDINALS = {0: "FIRST", 1: "SECOND", 2: "THIRD", 3: "FOURTH", 4: "FIFTH"}


def slugify(text: str, max_len: int = 40) -> str:
    slug = re.sub(r"[^\w\s-]", "", text.lower())
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")
    return slug[:max_len]


def color(text: str, code: str) -> str:
    """ANSI color wrapper (degrades to plain text if not a TTY)."""
    if not sys.stdout.isatty():
        return text
    codes = {"bold": "1", "dim": "2", "green": "32", "yellow": "33",
             "blue": "34", "magenta": "35", "cyan": "36", "red": "31"}
    return f"\033[{codes.get(code, '0')}m{text}\033[0m"


def detect_available_models(requested: list[str], require_all: bool = False) -> list[str]:
    """Filter to models whose CLI is actually installed.

    If require_all=True, exits with an error if any requested model is missing.
    """
    available = []
    missing = []
    for m in requested:
        cfg = MODEL_CONFIGS.get(m)
        if not cfg:
            print(color(f"  Error: Unknown model '{m}'.", "red"), file=sys.stderr)
            missing.append(m)
            continue
        binary = cfg["cmd"][0]
        if shutil.which(binary):
            available.append(m)
        else:
            print(color(f"  Error: '{binary}' not found in PATH (model: {m}).", "red"),
                  file=sys.stderr)
            missing.append(m)

    if require_all and missing:
        print(color(f"\nAbort: missing models: {', '.join(missing)}. "
                    "All requested debaters must be available.", "red"), file=sys.stderr)
        sys.exit(1)
    elif not require_all:
        for m in missing:
            print(color(f"  Warning: skipping {m} (not available).", "yellow"), file=sys.stderr)

    return available


def call_model(model_name: str, prompt: str) -> tuple[str | None, str | None]:
    """Invoke a model CLI and return (response_text, error_message)."""
    cfg = MODEL_CONFIGS[model_name]
    cmd = list(cfg["cmd"])

    env = os.environ.copy()
    for var in cfg.get("env_unset", []):
        env.pop(var, None)

    try:
        if cfg["prompt_mode"] == "arg":
            cmd.append(prompt)
            proc = subprocess.run(
                cmd, capture_output=True, text=True,
                timeout=cfg["timeout"], env=env,
            )
        else:
            proc = subprocess.run(
                cmd, input=prompt, capture_output=True, text=True,
                timeout=cfg["timeout"], env=env,
            )

        if proc.returncode != 0:
            stderr = proc.stderr.strip()[:500]
            return None, f"Exit {proc.returncode}: {stderr}"

        text = proc.stdout.strip()
        if not text:
            return None, "Empty response"
        return text, None

    except FileNotFoundError:
        return None, f"CLI binary not found: {cfg['cmd'][0]}"
    except subprocess.TimeoutExpired:
        return None, f"Timed out after {cfg['timeout']}s"


def parse_structured_footer(text: str) -> dict:
    """Extract STANCE / AGREEMENTS / DISAGREEMENTS / ISSUES / RESOLVED / KILL_ARGUMENT from the structured footer."""
    stance = ""
    agreements: list[str] = []
    disagreements: list[str] = []
    issues: list[str] = []
    resolved: list[str] = []
    kill_argument = ""

    parts = text.rsplit("---", 1)
    content = parts[0].strip() if len(parts) == 2 else text.strip()
    footer = parts[1] if len(parts) == 2 else ""

    for line in footer.split("\n"):
        line = line.strip()
        upper = line.upper()
        if upper.startswith("STANCE:"):
            stance = line.split(":", 1)[1].strip()
        elif upper.startswith("AGREEMENTS:"):
            raw = line.split(":", 1)[1].strip()
            if raw.lower() not in ("none yet", "n/a", "none", ""):
                agreements = [a.strip() for a in raw.split(",") if a.strip()]
        elif upper.startswith("DISAGREEMENTS:"):
            raw = line.split(":", 1)[1].strip()
            if raw.lower() not in ("none yet", "n/a", "none", ""):
                disagreements = [d.strip() for d in raw.split(",") if d.strip()]
        elif upper.startswith("ISSUES:"):
            raw = line.split(":", 1)[1].strip()
            if raw.lower() not in ("none", "n/a", ""):
                issues = [i.strip() for i in raw.split(",") if i.strip()]
        elif upper.startswith("RESOLVED:"):
            raw = line.split(":", 1)[1].strip()
            if raw.lower() not in ("none", "n/a", ""):
                resolved = [r.strip() for r in raw.split(",") if r.strip()]
        elif upper.startswith("KILL_ARGUMENT:"):
            kill_argument = line.split(":", 1)[1].strip()

    # Also check body content for KILL_ARGUMENT: (it may appear outside footer)
    if not kill_argument:
        for line in content.split("\n"):
            if line.strip().upper().startswith("KILL_ARGUMENT:"):
                kill_argument = line.strip().split(":", 1)[1].strip()
                break

    return {
        "content": content,
        "stance": stance,
        "agreements": agreements,
        "disagreements": disagreements,
        "issues": issues,
        "resolved": resolved,
        "kill_argument": kill_argument,
    }


_RATE_LIMIT_SIGNALS = [
    "429", "resource_exhausted", "quota exceeded",
    "rate limit", "too many requests", "rate_limit_exceeded",
]


def is_rate_limited(error_msg: str) -> bool:
    """Return True if the error looks like a transient rate-limit."""
    lower = error_msg.lower()
    return any(s in lower for s in _RATE_LIMIT_SIGNALS)


def classify_validity(parsed: dict) -> str:
    """Classify a parsed footer as 'substantive' or 'malformed_footer'."""
    if (not parsed.get("stance") and not parsed.get("agreements")
            and not parsed.get("disagreements")):
        return "malformed_footer"
    return "substantive"


def update_issue_register(convo: dict, turn: dict) -> None:
    """Update the conversation's issue register based on a turn's ISSUES/RESOLVED fields."""
    register = convo.setdefault("issue_register", [])

    # Add new issues
    for desc in turn.get("issues", []):
        issue_id = f"ISS-{len(register) + 1}"
        register.append({
            "id": issue_id,
            "description": desc,
            "status": "open",
            "raised_by": turn["model"],
            "round_raised": turn["round"],
        })

    # Resolve issues
    for issue_id in turn.get("resolved", []):
        for issue in register:
            if issue["id"] == issue_id.strip():
                issue["status"] = "resolved"


def parse_ratification_footer(text: str) -> dict:
    """Extract RATIFIES / OBJECTIONS / RESOLUTIONS from a ratification response."""
    parts = text.rsplit("---", 1)
    content = parts[0].strip() if len(parts) == 2 else text.strip()
    footer = parts[1] if len(parts) == 2 else ""

    ratifies = "unknown"
    objections: list[str] = []
    resolutions: list[str] = []

    for line in footer.split("\n"):
        line = line.strip()
        upper = line.upper()
        if upper.startswith("RATIFIES:"):
            ratifies = line.split(":", 1)[1].strip().lower()
        elif upper.startswith("OBJECTIONS:"):
            raw = line.split(":", 1)[1].strip()
            if raw.lower() not in ("none", "n/a", ""):
                objections = [o.strip() for o in raw.split(",") if o.strip()]
        elif upper.startswith("RESOLUTIONS:"):
            raw = line.split(":", 1)[1].strip()
            if raw.lower() not in ("none", "n/a", ""):
                resolutions = [r.strip() for r in raw.split(",") if r.strip()]

    return {"content": content, "ratifies": ratifies,
            "objections": objections, "resolutions": resolutions}


def build_ratify_prompt(convo: dict, model: str) -> str:
    """Build the ratification prompt, auto-deriving agreed/friction from conversation."""
    display_name = MODEL_CONFIGS.get(model, {}).get("display_name", model.title())
    num_rounds = max((t["round"] for t in convo["turns"]), default=0)
    max_words = convo["config"]["max_words"]

    # Collect agreements/disagreements from the last complete round
    last_round_turns = [t for t in convo["turns"] if t["round"] == num_rounds
                        and not t.get("error")]
    agreed: list[str] = []
    friction: list[str] = []
    for t in last_round_turns:
        agreed.extend(t.get("agreements", []))
        friction.extend(t.get("disagreements", []))

    # Deduplicate while preserving order
    seen: set[str] = set()
    agreed = [x for x in agreed if not (x in seen or seen.add(x))]  # type: ignore[func-returns-value]
    seen = set()
    friction = [x for x in friction if not (x in seen or seen.add(x))]  # type: ignore[func-returns-value]

    proposal = convo.get("proposal_artifact")
    if proposal:
        # Proposal ratification mode: replace debate summary with proposal
        friction_text = "\n".join(f"- {p}" for p in friction) if friction else "  (none — full consensus reached)"
        prompt = RATIFY_PROMPT.format(
            display_name=display_name,
            topic=convo["topic"],
            num_rounds=num_rounds,
            max_words=max_words,
            agreed_points="(see proposal below)",
            friction_points=friction_text,
        )
        # Replace the debate summary section with proposal
        prompt = prompt.replace(
            f"POINTS OF AGREEMENT reached during the debate:\n(see proposal below)\n\n"
            f"REMAINING FRICTION POINTS:\n{friction_text}",
            f"=== PROPOSAL TO RATIFY ===\n{proposal}\n\n"
            f"=== REMAINING FRICTION POINTS FROM DEBATE ===\n{friction_text}",
        )
    else:
        prompt = RATIFY_PROMPT.format(
            display_name=display_name,
            topic=convo["topic"],
            num_rounds=num_rounds,
            max_words=max_words,
            agreed_points="\n".join(f"- {p}" for p in agreed) if agreed else "  (none explicitly recorded)",
            friction_points="\n".join(f"- {p}" for p in friction) if friction else "  (none — full consensus reached)",
        )

    # Moderator mode: arbitrating
    moderator_mode = convo.get("config", {}).get("moderator_mode", "neutral")
    if moderator_mode == "arbitrating":
        prompt += ("\nIf debaters could not agree on a point, you may now recommend "
                   "a specific resolution. Clearly mark any such recommendation as "
                   "MODERATOR RECOMMENDATION.")

    return prompt


def format_history(turns: list[dict], compressed: bool = False) -> str:
    """Format conversation history for inclusion in prompts."""
    if not turns:
        return "(no conversation yet)"

    max_round = max(t["round"] for t in turns)
    lines: list[str] = []

    for t in turns:
        model_upper = t["model"].upper()
        if compressed and t["round"] < max_round - 1:
            lines.append(f"[{model_upper} - Round {t['round']}] STANCE: {t.get('stance', 'N/A')}")
        else:
            lines.append(f"[{model_upper} - Round {t['round']}]")
            lines.append(t["content"])
            if t.get("stance"):
                lines.append(f"  STANCE: {t['stance']}")
            if t.get("agreements"):
                lines.append(f"  AGREEMENTS: {', '.join(t['agreements'])}")
            if t.get("disagreements"):
                lines.append(f"  DISAGREEMENTS: {', '.join(t['disagreements'])}")
        lines.append("")

    return "\n".join(lines)


def check_convergence(turns: list[dict], round_num: int,
                      issue_register: list[dict] | None = None) -> tuple[bool, str]:
    """Mechanical convergence check: count remaining disagreements and open issues."""
    round_turns = [t for t in turns if t["round"] == round_num and not t.get("error")]

    if len(round_turns) < 2:
        return False, "Not enough participants this round"

    all_disagreements = []
    for t in round_turns:
        all_disagreements.extend(t.get("disagreements", []))

    # If issue register exists and has entries, require all issues resolved or deferred
    if issue_register:
        open_issues = [i for i in issue_register
                       if i["status"] not in ("resolved", "deferred")]
        if open_issues:
            return False, (f"{len(open_issues)} open issue(s) remain: "
                           f"{', '.join(i['id'] for i in open_issues)}")
        if not all_disagreements:
            return True, "All issues resolved/deferred and no remaining disagreements"

    if not all_disagreements:
        return True, "All participants report no remaining disagreements"

    if round_num >= 2:
        prev_turns = [t for t in turns if t["round"] == round_num - 1 and not t.get("error")]
        prev_disagreements = []
        for t in prev_turns:
            prev_disagreements.extend(t.get("disagreements", []))

        if len(all_disagreements) < len(prev_disagreements):
            return False, (
                f"Narrowing: {len(prev_disagreements)} -> {len(all_disagreements)} disagreement(s)"
            )

    return False, f"{len(all_disagreements)} disagreement(s) remain"


# ---------------------------------------------------------------------------
# Conversation state helpers
# ---------------------------------------------------------------------------

def get_round_info(convo: dict) -> dict:
    """Return current round number and which models still need to go."""
    models = convo["config"]["models"]
    max_rounds = convo["config"]["max_rounds"]

    if not convo["turns"]:
        return {"round": 1, "max_rounds": max_rounds,
                "pending": list(models), "completed": []}

    last_round = max(t["round"] for t in convo["turns"])
    completed_this_round = [
        t["model"] for t in convo["turns"] if t["round"] == last_round
    ]

    if set(completed_this_round) == set(models):
        # Current round is complete -- next round
        return {"round": last_round + 1, "max_rounds": max_rounds,
                "pending": list(models), "completed": []}
    else:
        pending = [m for m in models if m not in completed_this_round]
        return {"round": last_round, "max_rounds": max_rounds,
                "pending": pending, "completed": completed_this_round}


def build_prompt(convo: dict, model: str) -> str:
    """Build the debate prompt for a model's next turn."""
    topic = convo["topic"]
    context = convo.get("context", "")
    codebase_context = convo.get("codebase_context", "")
    models = convo["config"]["models"]
    max_rounds = convo["config"]["max_rounds"]
    max_words = convo["config"]["max_words"]

    info = get_round_info(convo)
    round_num = info["round"]
    model_index = models.index(model) if model in models else 0

    display_name = MODEL_CONFIGS.get(model, {}).get("display_name", model.title())

    preamble = SYSTEM_PREAMBLE.format(
        display_name=display_name,
        max_words=max_words,
    )

    # Gemini has file tools -- tell it to use them instead of reading static content
    has_file_tools = model == "gemini"
    if has_file_tools and codebase_context:
        codebase_section = (
            "\n\n=== CODEBASE ACCESS ===\n"
            "You have access to the full repository via your file tools.\n"
            "Key files to read when relevant:\n"
            + "\n".join(
                f"  - {line}" for line in codebase_context.strip().splitlines()
                if line.strip().startswith("-") or line.strip().endswith((".py", ".ts", ".md", ".sh"))
            )
            + "\nRead these files to ground your arguments in actual code."
        )
    elif codebase_context:
        codebase_section = f"\n\n=== CODEBASE REFERENCE ===\n{codebase_context}"
    else:
        codebase_section = ""

    # Blind opening round: ALL speakers in round 1 get the FIRST_TURN template
    # with no conversation history, regardless of speaker order.
    if round_num == 1:
        prompt = FIRST_TURN.format(
            preamble=preamble,
            topic=topic,
            context=f"\nContext: {context}" if context else "",
            codebase_section=codebase_section,
            participants=", ".join(
                MODEL_CONFIGS.get(m, {}).get("display_name", m.title())
                for m in models
            ),
            order=ORDINALS.get(model_index, f"#{model_index+1}"),
        )
        # Design mode kill gate: append to round 1 prompts
        discussion_mode = convo.get("config", {}).get("discussion_mode", "audit")
        if discussion_mode == "design":
            prompt += KILL_GATE
        return prompt

    urgency = ""
    if round_num == max_rounds:
        urgency = URGENCY_FINAL
    elif round_num == max_rounds - 1:
        urgency = URGENCY_PENULTIMATE

    compressed = round_num > 3
    history = format_history(convo["turns"], compressed=compressed)

    # Build issue register section so models can reference ISS-* IDs
    issue_register = convo.get("issue_register", [])
    if issue_register:
        lines = ["\n=== OPEN ISSUES (use these IDs in your RESOLVED: footer) ==="]
        for issue in issue_register:
            status_marker = f"[{issue['status'].upper()}]"
            lines.append(
                f"  {issue['id']} {status_marker}: {issue['description']} "
                f"(raised by {issue['raised_by']}, round {issue['round_raised']})"
            )
        issue_register_section = "\n".join(lines) + "\n"
    else:
        issue_register_section = ""

    return FOLLOW_TURN.format(
        preamble=preamble,
        topic=topic,
        codebase_section=codebase_section,
        history=history,
        issue_register_section=issue_register_section,
        round_num=round_num,
        max_rounds=max_rounds,
        urgency=urgency,
    )


def make_turn(model: str, round_num: int, response: str | None,
              error: str | None) -> dict:
    """Build a turn dict from a response or error."""
    now = datetime.now(timezone.utc).isoformat()
    if error or response is None:
        # Classify the error type for validity tracking
        if error and "timed out" in error.lower():
            validity = "timed_out"
        elif error and ("empty" in error.lower() or response is None):
            validity = "empty_response"
        else:
            validity = "empty_response"
        return {
            "round": round_num,
            "model": model,
            "content": f"[SKIPPED: {error}]",
            "stance": "",
            "agreements": [],
            "disagreements": [],
            "issues": [],
            "resolved": [],
            "timestamp": now,
            "error": error or "No response",
            "validity": validity,
        }

    parsed = parse_structured_footer(response)
    validity = classify_validity(parsed)
    turn = {
        "round": round_num,
        "model": model,
        "content": parsed["content"],
        "stance": parsed["stance"],
        "agreements": parsed["agreements"],
        "disagreements": parsed["disagreements"],
        "issues": parsed["issues"],
        "resolved": parsed["resolved"],
        "raw_response": response,
        "timestamp": now,
        "validity": validity,
    }
    if parsed.get("kill_argument"):
        turn["kill_argument"] = parsed["kill_argument"]
    return turn


# ---------------------------------------------------------------------------
# Conversation file management
# ---------------------------------------------------------------------------

def create_conversation(
    topic: str,
    context: str = "",
    codebase_context: str = "",
    models: list[str] | None = None,
    max_rounds: int = 5,
    max_words: int = 400,
    discussion_mode: str = "audit",
    moderator_mode: str = "neutral",
) -> Path:
    models = models or list(DEFAULT_DEBATERS)
    now = datetime.now(timezone.utc)
    slug = slugify(topic)
    filename = f"convo-{slug}-{now.strftime('%Y%m%dT%H%M%S')}.json"

    convo = {
        "topic": topic,
        "context": context,
        "codebase_context": codebase_context,
        "created_at": now.isoformat(),
        "config": {
            "max_rounds": max_rounds,
            "max_words": max_words,
            "models": models,
            "discussion_mode": discussion_mode,
            "moderator_mode": moderator_mode,
        },
        "turns": [],
        "convergence_checks": [],
        "issue_register": [],
        "status": "in_progress",
        "final_report": None,
    }

    CONVO_DIR.mkdir(parents=True, exist_ok=True)
    filepath = CONVO_DIR / filename
    filepath.write_text(json.dumps(convo, indent=2))
    return filepath


def save_conversation(filepath: Path, convo: dict) -> None:
    """Atomic save: write to tmp, then rename."""
    tmp = filepath.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(convo, indent=2))
    tmp.rename(filepath)


# ---------------------------------------------------------------------------
# Step commands (for external moderator orchestration)
# ---------------------------------------------------------------------------

def cmd_run_turn(filepath: Path, model: str) -> None:
    """Run one model's turn via its CLI. Appends to conversation."""
    convo = json.loads(filepath.read_text())
    info = get_round_info(convo)

    if model not in info["pending"]:
        print(f"Error: {model} already completed round {info['round']}",
              file=sys.stderr)
        sys.exit(1)

    # Verify CLI is reachable before attempting
    cfg = MODEL_CONFIGS.get(model)
    if not cfg or not shutil.which(cfg["cmd"][0]):
        print(color(f"\nAbort: {model} CLI ('{cfg['cmd'][0] if cfg else model}') not found. "
                    "Discussion cancelled -- all 3 debaters must be available.", "red"),
              file=sys.stderr)
        sys.exit(2)

    prompt = build_prompt(convo, model)

    print(f"  [{color(model.upper(), 'bold')}] Thinking...",
          end="", flush=True, file=sys.stderr)
    response, error = call_model(model, prompt)

    if error and is_rate_limited(error):
        # Rate limit: do NOT save a SKIPPED turn — let the moderator retry
        print(color(f" RATE LIMITED ({error})", "yellow"), file=sys.stderr)
        print(color("  Retry: wait 30-60s then re-run this --run-turn command.", "yellow"),
              file=sys.stderr)
        sys.exit(3)  # exit 3 = rate limited (retriable), turn NOT saved

    turn = make_turn(model, info["round"], response, error)
    convo["turns"].append(turn)
    update_issue_register(convo, turn)
    save_conversation(filepath, convo)

    if error:
        print(color(f" SKIPPED ({error})", "red"), file=sys.stderr)
    else:
        word_count = len(turn["content"].split())
        print(color(" Done", "green") + f" ({word_count} words)", file=sys.stderr)
        if turn["stance"]:
            print(f"    STANCE: {turn['stance']}", file=sys.stderr)


def cmd_get_prompt(filepath: Path, model: str) -> None:
    """Print the next prompt for a model to stdout (for subagent use)."""
    convo = json.loads(filepath.read_text())
    prompt = build_prompt(convo, model)
    # Print to stdout only -- no decoration, no stderr noise
    print(prompt)


def cmd_add_response(filepath: Path, model: str) -> None:
    """Read a response from stdin and add it as a turn."""
    convo = json.loads(filepath.read_text())
    info = get_round_info(convo)

    if model not in info["pending"]:
        print(f"Error: {model} already completed round {info['round']}",
              file=sys.stderr)
        sys.exit(1)

    response = sys.stdin.read().strip()
    if not response:
        print("Error: empty response on stdin", file=sys.stderr)
        sys.exit(1)

    turn = make_turn(model, info["round"], response, None)
    convo["turns"].append(turn)
    update_issue_register(convo, turn)
    save_conversation(filepath, convo)

    word_count = len(turn["content"].split())
    print(f"  [{model.upper()}] Added ({word_count} words)", file=sys.stderr)
    if turn["stance"]:
        print(f"    STANCE: {turn['stance']}", file=sys.stderr)


def cmd_save_report(filepath: Path) -> None:
    """Read a structured JSON report from stdin and save it into final_report."""
    raw = sys.stdin.read().strip()
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"Error: --save-report expects JSON on stdin: {e}", file=sys.stderr)
        sys.exit(1)

    required = {"conclusion", "key_takeaways", "friction_points", "synthesis"}
    missing = required - report.keys()
    if missing:
        print(f"Error: report JSON missing required fields: {missing}", file=sys.stderr)
        sys.exit(1)

    convo = json.loads(filepath.read_text())
    report.setdefault("problem_statement", convo.get("context", ""))
    report.setdefault("prd_file", None)
    report["saved_at"] = datetime.now(timezone.utc).isoformat()
    convo["final_report"] = report
    save_conversation(filepath, convo)
    print(f"  [REPORT] Saved to {filepath}", file=sys.stderr)


def cmd_get_ratify_prompt(filepath: Path, model: str) -> None:
    """Print the ratification prompt for a model to stdout (for subagent use)."""
    convo = json.loads(filepath.read_text())
    print(build_ratify_prompt(convo, model))


def cmd_ratify(filepath: Path, model: str) -> None:
    """Run the ratification turn for a CLI model. Saves to convo['ratifications']."""
    convo = json.loads(filepath.read_text())

    cfg = MODEL_CONFIGS.get(model)
    if not cfg or not shutil.which(cfg["cmd"][0]):
        print(color(f"\nAbort: {model} CLI not found.", "red"), file=sys.stderr)
        sys.exit(2)

    prompt = build_ratify_prompt(convo, model)
    print(f"  [{color(model.upper(), 'bold')}] Ratifying...", end="", flush=True, file=sys.stderr)
    response, error = call_model(model, prompt)

    if error and is_rate_limited(error):
        print(color(f" RATE LIMITED ({error})", "yellow"), file=sys.stderr)
        print(color("  Retry: wait 30-60s then re-run this --ratify command.", "yellow"), file=sys.stderr)
        sys.exit(3)

    now = datetime.now(timezone.utc).isoformat()
    if error or not response:
        entry = {"ratifies": "error", "objections": [], "resolutions": [],
                 "content": "", "error": error or "No response", "timestamp": now}
        print(color(f" FAILED ({error})", "red"), file=sys.stderr)
    else:
        parsed = parse_ratification_footer(response)
        entry = {**parsed, "timestamp": now}
        print(color(" Done", "green"), file=sys.stderr)
        print(f"    RATIFIES: {entry['ratifies']}", file=sys.stderr)
        if entry["objections"]:
            print(f"    OBJECTIONS: {', '.join(entry['objections'])}", file=sys.stderr)

    convo.setdefault("ratifications", {})[model] = entry
    save_conversation(filepath, convo)


def cmd_add_ratification(filepath: Path, model: str) -> None:
    """Read a ratification response from stdin and record it (for subagent use)."""
    convo = json.loads(filepath.read_text())
    response = sys.stdin.read().strip()
    if not response:
        print("Error: empty response on stdin", file=sys.stderr)
        sys.exit(1)

    parsed = parse_ratification_footer(response)
    entry = {**parsed, "timestamp": datetime.now(timezone.utc).isoformat()}
    convo.setdefault("ratifications", {})[model] = entry
    save_conversation(filepath, convo)

    print(f"  [{model.upper()}] Ratification recorded: {entry['ratifies']}", file=sys.stderr)
    if entry["objections"]:
        print(f"    OBJECTIONS: {', '.join(entry['objections'])}", file=sys.stderr)


def cmd_set_proposal(filepath: Path) -> None:
    """Read a proposal artifact from stdin and store it in the conversation."""
    convo = json.loads(filepath.read_text())
    proposal = sys.stdin.read().strip()
    if not proposal:
        print("Error: empty proposal on stdin", file=sys.stderr)
        sys.exit(1)

    convo["proposal_artifact"] = proposal
    save_conversation(filepath, convo)
    print(f"  [PROPOSAL] Stored ({len(proposal)} chars) in {filepath.name}",
          file=sys.stderr)


def cmd_status(filepath: Path) -> None:
    """Print conversation status as JSON to stdout."""
    convo = json.loads(filepath.read_text())
    info = get_round_info(convo)

    # Check convergence for the most recent complete round
    last_complete_round = 0
    models = set(convo["config"]["models"])
    for r in range(info["round"], 0, -1):
        round_models = {t["model"] for t in convo["turns"] if t["round"] == r}
        if round_models == models:
            last_complete_round = r
            break

    issue_register = convo.get("issue_register", [])

    converged = False
    reason = "No complete round yet"
    if last_complete_round > 0:
        converged, reason = check_convergence(
            convo["turns"], last_complete_round,
            issue_register=issue_register or None,
        )

        # Record convergence check if not already recorded for this round
        recorded_rounds = {c["after_round"] for c in convo["convergence_checks"]}
        if last_complete_round not in recorded_rounds:
            convo["convergence_checks"].append({
                "after_round": last_complete_round,
                "converged": converged,
                "reason": reason,
            })
            if converged and last_complete_round >= 2:
                convo["status"] = "converged"
            elif info["round"] > convo["config"]["max_rounds"]:
                convo["status"] = "max_rounds_reached"
            save_conversation(filepath, convo)

    ratifications = convo.get("ratifications", {})
    ratified_by = [m for m, r in ratifications.items() if r.get("ratifies") == "yes"]
    ratify_pending = [m for m in convo["config"]["models"] if m not in ratifications]

    # Quality metrics
    turns = convo["turns"]
    substantive = sum(1 for t in turns if t.get("validity") == "substantive")
    malformed = sum(1 for t in turns if t.get("validity") == "malformed_footer")
    empty = sum(1 for t in turns if t.get("validity") == "empty_response")
    timed_out = sum(1 for t in turns if t.get("validity") == "timed_out")
    rate_limited = sum(1 for t in turns if t.get("validity") == "rate_limited")

    # Count position changes: turns where stance differs from same model's previous stance
    position_changes = 0
    last_stance: dict[str, str] = {}
    for t in turns:
        model_name = t["model"]
        stance = t.get("stance", "")
        if model_name in last_stance and stance and stance != last_stance[model_name]:
            position_changes += 1
        if stance:
            last_stance[model_name] = stance

    quality_metrics = {
        "substantive_turns": substantive,
        "malformed_turns": malformed,
        "empty_turns": empty,
        "timed_out_turns": timed_out,
        "rate_limited_turns": rate_limited,
        "position_changes": position_changes,
        "unique_issues": len(issue_register),
    }

    status = {
        "round": info["round"],
        "max_rounds": info["max_rounds"],
        "pending": info["pending"],
        "completed": info["completed"],
        "converged": converged,
        "reason": reason,
        "status": convo["status"],
        "total_turns": len(turns),
        "ratified_by": ratified_by,
        "ratify_pending": ratify_pending,
        "quality_metrics": quality_metrics,
        "file": str(filepath),
    }
    print(json.dumps(status, indent=2))


# ---------------------------------------------------------------------------
# Full-auto discussion loop
# ---------------------------------------------------------------------------

def run_discussion(filepath: Path, with_synthesis: bool = False,
                   require_all: bool = True) -> dict:
    """Run the full debate automatically. CLI-based models only."""
    convo = json.loads(filepath.read_text())
    topic = convo["topic"]
    cfg = convo["config"]
    max_rounds = cfg["max_rounds"]
    max_words = cfg["max_words"]

    models = detect_available_models(cfg["models"], require_all=require_all)
    if len(models) < 2:
        print(color("Error: Need at least 2 available model CLIs for a debate.",
                     "red"), file=sys.stderr)
        sys.exit(1)

    print(f"\n{'=' * 60}")
    print(color(f"  TOPIC: {topic}", "bold"))
    print(f"  Debaters: {', '.join(models)}")
    print(f"  Max rounds: {max_rounds} | Max words/turn: {max_words}")
    print(f"  Moderator: {'debater-generated' if with_synthesis else 'external'}")
    print(f"  File: {filepath.name}")
    print(f"{'=' * 60}\n")

    # Determine starting round
    start_round = 1
    if convo["turns"]:
        last_round = max(t["round"] for t in convo["turns"])
        last_round_models = {t["model"] for t in convo["turns"]
                             if t["round"] == last_round}
        start_round = last_round if last_round_models != set(models) else last_round + 1

    for round_num in range(start_round, max_rounds + 1):
        print(color(f"\n--- Round {round_num} of {max_rounds} ---\n", "cyan"))

        for i, model in enumerate(models):
            existing = [t for t in convo["turns"]
                        if t["round"] == round_num and t["model"] == model]
            if existing:
                print(f"  [{model.upper()}] (already completed, skipping)")
                continue

            prompt = build_prompt(convo, model)

            print(f"  [{color(model.upper(), 'bold')}] Thinking...",
                  end="", flush=True)
            response, error = call_model(model, prompt)

            turn = make_turn(model, round_num, response, error)

            if error:
                print(color(f" SKIPPED ({error})", "red"))
            else:
                word_count = len(turn["content"].split())
                print(color(" Done", "green") + f" ({word_count} words)")
                if turn["stance"]:
                    print(f"    {color('STANCE:', 'dim')} {turn['stance']}")
                if turn["agreements"]:
                    print(f"    {color('AGREES:', 'dim')} "
                          f"{', '.join(turn['agreements'][:3])}")
                if turn["disagreements"]:
                    print(f"    {color('DISAGREES:', 'dim')} "
                          f"{', '.join(turn['disagreements'][:3])}")

            convo["turns"].append(turn)
            update_issue_register(convo, turn)
            save_conversation(filepath, convo)

        # Convergence check
        issue_register = convo.get("issue_register", [])
        converged, reason = check_convergence(
            convo["turns"], round_num,
            issue_register=issue_register or None,
        )
        convo["convergence_checks"].append({
            "after_round": round_num,
            "converged": converged,
            "reason": reason,
        })

        icon = color("YES", "green") if converged else color("No", "yellow")
        print(f"\n  Convergence: {icon} -- {reason}")

        if converged and round_num >= 2:
            convo["status"] = "converged"
            save_conversation(filepath, convo)
            print(color(f"\n  Discussion converged after round {round_num}!",
                        "green"))
            break
    else:
        convo["status"] = "max_rounds_reached"
        save_conversation(filepath, convo)
        print(color(f"\n  Max rounds ({max_rounds}) reached.", "yellow"))

    # Optional self-synthesis
    if with_synthesis:
        print(color("\n--- Generating Synthesis (debater-mode) ---\n", "cyan"))
        model_headers = " | ".join(
            MODEL_CONFIGS.get(m, {}).get("display_name", m.title())
            for m in models
        )
        synthesis_prompt = (
            f"You are a neutral moderator. Analyze this multi-AI discussion and "
            f"produce a final report. Do NOT add your own opinions.\n\n"
            f"=== TOPIC ===\n{topic}\n\n"
            f"=== FULL CONVERSATION ===\n"
            f"{format_history(convo['turns'], compressed=False)}\n\n"
            f"Generate a markdown report with: Consensus Position, Key "
            f"Disagreements, Synthesis & Recommendation, Confidence Assessment, "
            f"Stance Evolution table (columns: {model_headers})."
        )
        report = None
        for m in models:
            print(f"  Synthesizer: {m.upper()}...", end="", flush=True)
            report, err = call_model(m, synthesis_prompt)
            if report:
                print(color(" Done", "green"))
                break
            print(color(f" Failed ({err})", "red"))

        convo["final_report"] = report or "[All models failed to generate synthesis]"
        save_conversation(filepath, convo)
        print(f"\n{'=' * 60}")
        print(convo["final_report"])
        print(f"{'=' * 60}")

    total_rounds = max(t["round"] for t in convo["turns"]) if convo["turns"] else 0
    print(f"\nDebate complete.")
    print(f"  File: {color(str(filepath), 'cyan')}")
    print(f"  Status: {convo['status']}")
    print(f"  Rounds: {total_rounds}")
    if not with_synthesis:
        print(f"  Synthesis: awaiting external moderator")

    return convo


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Multi-AI Discussion Orchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Full-auto mode (runs entire debate):
  %(prog)s "How should we architect X?"
  %(prog)s "Best approach?" --max-rounds 3 --models gemini codex
  %(prog)s --resume convo.json
  %(prog)s "Topic" --self-synthesize

Step-by-step mode (for external moderator):
  %(prog)s "Topic" --models gemini codex claude --create-only
  %(prog)s --resume convo.json --run-turn gemini
  %(prog)s --resume convo.json --run-turn codex
  %(prog)s --resume convo.json --get-prompt claude       # prints to stdout
  echo "$resp" | %(prog)s --resume convo.json --add-response claude
  %(prog)s --resume convo.json --status
        """,
    )
    # --- Topic and conversation setup ---
    parser.add_argument("topic", nargs="?", help="Discussion topic or question")
    parser.add_argument("--context", "-c", default="",
                        help="Additional context for the discussion")
    parser.add_argument("--codebase-files", nargs="+", metavar="FILE",
                        help="Files to read and inject into debater prompts as codebase "
                             "reference. For Gemini, these become a guided file list "
                             "(it has autonomous file tools). For Codex/Claude, file "
                             "contents are injected directly into the prompt.")
    parser.add_argument("--max-rounds", "-r", type=int, default=5,
                        help="Maximum discussion rounds (default: 5)")
    parser.add_argument("--max-words", "-w", type=int, default=400,
                        help="Max words per turn (default: 400)")
    parser.add_argument("--models", "-m", nargs="+",
                        default=DEFAULT_DEBATERS,
                        help=f"Debater models (default: {' '.join(DEFAULT_DEBATERS)})")
    parser.add_argument("--resume", help="Resume from existing conversation file")

    # --- Mode flags ---
    parser.add_argument("--create-only", action="store_true",
                        help="Create conversation file and exit (print path)")
    parser.add_argument("--self-synthesize", action="store_true",
                        help="Have a debater generate the synthesis report")
    parser.add_argument("--allow-missing-models", action="store_true",
                        help="Continue with fewer debaters if a CLI is unavailable "
                             "(default: abort if any model is missing)")

    # --- Step commands (require --resume) ---
    parser.add_argument("--run-turn",
                        help="Run one MODEL's turn via CLI", metavar="MODEL")
    parser.add_argument("--get-prompt",
                        help="Print next prompt for MODEL to stdout",
                        metavar="MODEL")
    parser.add_argument("--add-response",
                        help="Read response from stdin for MODEL",
                        metavar="MODEL")
    parser.add_argument("--status", action="store_true",
                        help="Print conversation status as JSON")
    parser.add_argument("--save-report", action="store_true",
                        help="Read structured JSON report from stdin and save "
                             "into final_report field of the conversation file")
    parser.add_argument("--ratify",
                        help="Run ratification turn for MODEL via CLI", metavar="MODEL")
    parser.add_argument("--get-ratify-prompt",
                        help="Print ratification prompt for MODEL to stdout",
                        metavar="MODEL")
    parser.add_argument("--add-ratification",
                        help="Read ratification response from stdin for MODEL",
                        metavar="MODEL")
    parser.add_argument("--set-proposal", action="store_true",
                        help="Read proposal artifact from stdin and store it "
                             "in the conversation for ratification")

    # --- Discussion mode flags ---
    parser.add_argument("--mode", choices=["audit", "design"], default="audit",
                        help="Discussion mode: audit (default) or design (adds kill gate)")
    parser.add_argument("--moderator-mode", choices=["neutral", "arbitrating"],
                        default="neutral",
                        help="Moderator mode: neutral (default) or arbitrating")

    args = parser.parse_args()

    # --- Resolve conversation file path ---
    filepath = None
    if args.resume:
        filepath = Path(args.resume)
        if not filepath.exists():
            print(f"Error: {filepath} not found", file=sys.stderr)
            sys.exit(1)

    # --- Dispatch step commands ---
    step_cmd = (args.run_turn or args.get_prompt or args.add_response
                or args.status or args.save_report
                or args.ratify or args.get_ratify_prompt or args.add_ratification
                or args.set_proposal)
    require_all = not args.allow_missing_models

    if step_cmd:
        if not filepath:
            print("Error: step commands require --resume <convo.json>",
                  file=sys.stderr)
            sys.exit(1)

        if args.run_turn:
            cmd_run_turn(filepath, args.run_turn)
        elif args.get_prompt:
            cmd_get_prompt(filepath, args.get_prompt)
        elif args.add_response:
            cmd_add_response(filepath, args.add_response)
        elif args.status:
            cmd_status(filepath)
        elif args.save_report:
            cmd_save_report(filepath)
        elif args.ratify:
            cmd_ratify(filepath, args.ratify)
        elif args.get_ratify_prompt:
            cmd_get_ratify_prompt(filepath, args.get_ratify_prompt)
        elif args.add_ratification:
            cmd_add_ratification(filepath, args.add_ratification)
        elif args.set_proposal:
            cmd_set_proposal(filepath)
        return

    # --- Read codebase files if requested ---
    codebase_context = ""
    if getattr(args, "codebase_files", None):
        parts = []
        for pattern in args.codebase_files:
            import glob as _glob
            matched = sorted(_glob.glob(pattern, recursive=True))
            if not matched:
                # Try relative to repo root
                matched = sorted(_glob.glob(str(REPO_ROOT / pattern), recursive=True))
            for path in matched:
                try:
                    content = Path(path).read_text(encoding="utf-8", errors="replace")
                    # Truncate very large files to avoid context overflow
                    if len(content) > 8000:
                        content = content[:8000] + "\n... (truncated)"
                    parts.append(f"### {path}\n```\n{content}\n```")
                except OSError as exc:
                    parts.append(f"### {path}\n[Error reading: {exc}]")
        codebase_context = "\n\n".join(parts)

    # --- Create-only mode ---
    if args.topic and args.create_only:
        filepath = create_conversation(
            topic=args.topic,
            context=args.context,
            codebase_context=codebase_context,
            models=args.models,
            max_rounds=args.max_rounds,
            max_words=args.max_words,
            discussion_mode=args.mode,
            moderator_mode=args.moderator_mode,
        )
        print(filepath)  # stdout: just the path
        return

    # --- Full-auto mode ---
    if not filepath and args.topic:
        filepath = create_conversation(
            topic=args.topic,
            context=args.context,
            codebase_context=codebase_context,
            models=args.models,
            max_rounds=args.max_rounds,
            max_words=args.max_words,
            discussion_mode=args.mode,
            moderator_mode=args.moderator_mode,
        )
    elif not filepath:
        parser.print_help()
        sys.exit(1)

    run_discussion(filepath, with_synthesis=args.self_synthesize, require_all=require_all)


if __name__ == "__main__":
    main()
