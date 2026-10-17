#!/usr/bin/env python3
"""Build a GitHub Review payload from the strict-review model response.

The model is asked for a bare JSON object. This script tolerates a fenced block,
validates the shape, and turns comments whose line numbers are outside the
reviewed diff into body text so the Review API does not reject the whole payload
with a 422.

Usage:
    render-pr-review.py --response FILE --context FILE --head SHA --output FILE

Exit code is 0 even when the response cannot be parsed: a fallback payload is
written and a GitHub warning is emitted. The workflow can still post the Review.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

VERDICT_EMOJI = {"PASS": "✅", "NEEDS_ATTENTION": "⚠️"}
CATEGORY_EMOJI = {"REDLINE": "🚫", "ENGINEERING": "🔧"}
SEVERITY_EMOJI = {"ERROR": "❌", "WARNING": "⚠️", "INFO": "💡"}


def warn(message: str) -> None:
    print(f"::warning::{message}", file=sys.stderr)


def parse_response(text: str) -> dict:
    text = text.strip()
    match = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
    raw = match.group(1) if match else text
    return json.loads(raw)


def valid_lines_from_context(path: Path) -> dict[str, set[int]]:
    valid: dict[str, set[int]] = {}
    current: str | None = None
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if line.startswith("文件: "):
                    current = line[len("文件: ") :].strip()
                    valid.setdefault(current, set())
                elif current and line.startswith("[L"):
                    end = line.find("]")
                    try:
                        valid[current].add(int(line[2:end]))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return valid


def as_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--response", required=True)
    parser.add_argument("--context", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    raw = Path(args.response).read_text(encoding="utf-8", errors="replace")
    if not raw.strip():
        warn("模型返回为空，写入 fallback Review")
        data = {
            "summary": "审查结果为空，请查看工作流日志。",
            "verdict": "NEEDS_ATTENTION",
            "comments": [],
        }
    else:
        try:
            data = parse_response(raw)
            if not isinstance(data, dict):
                raise ValueError("response root is not an object")
        except (json.JSONDecodeError, ValueError) as error:
            warn(f"AI 响应 JSON 解析失败（{error}），原始内容保留在 response.txt")
            data = {
                "summary": "审查结果解析异常，请查看工作流日志（response.txt）。",
                "verdict": "NEEDS_ATTENTION",
                "comments": [],
            }

    summary = data.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        summary = "审查已完成。"
    verdict = data.get("verdict")
    if verdict not in VERDICT_EMOJI:
        verdict = "NEEDS_ATTENTION"
    comments = data.get("comments")
    if not isinstance(comments, list):
        comments = []

    valid_lines = valid_lines_from_context(Path(args.context))
    fallback_notes: list[str] = []
    payload_comments: list[dict] = []

    for item in comments:
        if not isinstance(item, dict):
            continue
        path = item.get("path")
        line = as_int(item.get("line"))
        if not isinstance(path, str) or not path or line is None or line <= 0:
            continue
        message = item.get("message")
        if not isinstance(message, str) or not message.strip():
            continue
        category = item.get("category") if item.get("category") in CATEGORY_EMOJI else "ENGINEERING"
        severity = item.get("severity") if item.get("severity") in SEVERITY_EMOJI else "WARNING"

        if valid_lines and (path not in valid_lines or line not in valid_lines[path]):
            fallback_notes.append(
                f"- {SEVERITY_EMOJI[severity]} **[{category} / {severity}]** `{path}:{line}` {message}"
            )
            continue

        body = f"{SEVERITY_EMOJI[severity]} **[{CATEGORY_EMOJI[category]} {category} / {severity}]** {message}"
        comment: dict[str, object] = {
            "path": path,
            "line": line,
            "side": "RIGHT",
            "body": body,
        }
        start_line = as_int(item.get("start_line"))
        if start_line is not None and start_line < line and (
            not valid_lines or (path in valid_lines and start_line in valid_lines[path])
        ):
            comment["start_line"] = start_line
            comment["start_side"] = "RIGHT"
        payload_comments.append(comment)

    short_head = args.head[:7]
    body_lines = [
        "### 🔍 Caelestia PR 严格型审查结论",
        "",
        f"- {VERDICT_EMOJI[verdict]} **结论**: {verdict}",
        f"- 📝 **概括**: {summary}",
        f"- 🔖 **Commit**: `{short_head}`",
        "",
        f"<!-- caelestia-pr-review: head={short_head} -->",
    ]
    if fallback_notes:
        body_lines += [
            "",
            "---",
            "**⚠️ 以下批注因行号不在本次 diff 内，无法贴到具体行：**",
            "",
            *fallback_notes,
        ]

    payload = {
        "commit_id": args.head,
        "body": "\n".join(body_lines),
        "event": "COMMENT",
        "comments": payload_comments,
    }

    Path(args.output).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Review payload: {len(payload_comments)} 条行级批注，{len(fallback_notes)} 条降级到正文")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
