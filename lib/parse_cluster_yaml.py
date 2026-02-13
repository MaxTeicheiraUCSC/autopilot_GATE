#!/usr/bin/env python3
"""Parse cluster.yaml and emit shell variable assignments.

Usage:
    python3 parse_cluster_yaml.py <path-to-cluster.yaml>

Output (eval-safe shell assignments):
    NUM_JOBS=2
    JOB_0_NAME=simulation
    JOB_0_SCRIPT=submit_gate.sbatch
    JOB_0_TYPE=sbatch
    JOB_0_ARRAY=1-10
    JOB_0_DEPENDS_ON=
    JOB_1_NAME=merge_results
    JOB_1_SCRIPT=merge_results.sbatch
    JOB_1_TYPE=sbatch
    JOB_1_ARRAY=
    JOB_1_DEPENDS_ON=simulation
    CLAUDE_ENABLED=true
    CLAUDE_AUTO_FIX=true
    CLAUDE_MAX_FIX_CYCLES=3
    CLAUDE_REVIEW_MODEL=sonnet
    CLAUDE_FIX_MODEL=opus
    CLAUDE_REVIEW_BUDGET=0.50
    CLAUDE_FIX_BUDGET=1.00
"""

import sys
import yaml
import shlex


def shell_escape(value):
    """Escape a value for safe shell assignment."""
    if value is None:
        return ""
    return shlex.quote(str(value))


def parse_cluster_yaml(path):
    with open(path, "r") as f:
        config = yaml.safe_load(f)

    lines = []

    # Parse project metadata
    project = config.get("project", {})
    if project:
        lines.append(f"PROJECT_NAME={shell_escape(project.get('name', ''))}")

    # Parse jobs
    jobs = config.get("jobs", [])
    lines.append(f"NUM_JOBS={len(jobs)}")

    for i, job in enumerate(jobs):
        name = job.get("name", f"job_{i}")
        lines.append(f"JOB_{i}_NAME={shell_escape(name)}")
        lines.append(f"JOB_{i}_SCRIPT={shell_escape(job.get('script', ''))}")
        lines.append(f"JOB_{i}_TYPE={shell_escape(job.get('type', 'sbatch'))}")
        lines.append(f"JOB_{i}_ARRAY={shell_escape(job.get('array', ''))}")

        # Dependencies (comma-separated list of job names)
        depends = job.get("depends_on", [])
        if isinstance(depends, str):
            depends = [depends]
        lines.append(f"JOB_{i}_DEPENDS_ON={shell_escape(','.join(depends))}")

        # Extra sbatch flags
        extra = job.get("sbatch_flags", "")
        lines.append(f"JOB_{i}_SBATCH_FLAGS={shell_escape(extra)}")

    # Parse Claude config
    claude = config.get("claude", {})
    lines.append(f"CLAUDE_ENABLED={shell_escape(str(claude.get('enabled', False)).lower())}")
    lines.append(f"CLAUDE_AUTO_FIX={shell_escape(str(claude.get('auto_fix', False)).lower())}")
    lines.append(f"CLAUDE_MAX_FIX_CYCLES={shell_escape(claude.get('max_fix_cycles', 3))}")
    lines.append(f"CLAUDE_REVIEW_MODEL={shell_escape(claude.get('review_model', 'sonnet'))}")
    lines.append(f"CLAUDE_FIX_MODEL={shell_escape(claude.get('fix_model', 'opus'))}")
    lines.append(f"CLAUDE_REVIEW_BUDGET={shell_escape(claude.get('review_budget', '0.50'))}")
    lines.append(f"CLAUDE_FIX_BUDGET={shell_escape(claude.get('fix_budget', '1.00'))}")

    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <cluster.yaml>", file=sys.stderr)
        sys.exit(1)

    try:
        output = parse_cluster_yaml(sys.argv[1])
        print(output)
    except FileNotFoundError:
        print(f"Error: {sys.argv[1]} not found", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error parsing YAML: {e}", file=sys.stderr)
        sys.exit(1)
