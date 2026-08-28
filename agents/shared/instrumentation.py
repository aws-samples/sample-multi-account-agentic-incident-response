"""Instrumentation wrapper — tracks tool calls, token usage, and duration.

Provides both a decorator and a context-manager interface for building the
report telemetry block.
"""

from __future__ import annotations

import functools
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any, Callable, Generator


@dataclass
class InstrumentationContext:
    """Accumulates telemetry for a single investigation run."""

    tool_calls: int = 0
    tokens: int = 0
    round_trips: int = 0
    _start_time: float = field(default_factory=time.time, repr=False)

    @property
    def duration_seconds(self) -> float:
        """Elapsed wall-clock time since context creation."""
        return time.time() - self._start_time

    def record_tool_call(self) -> None:
        """Increment tool call counter."""
        self.tool_calls += 1

    def record_tokens(self, count: int) -> None:
        """Add *count* tokens to the running total."""
        self.tokens += count

    def record_round_trip(self) -> None:
        """Increment round-trip counter (one LLM turn)."""
        self.round_trips += 1

    def to_telemetry_dict(self) -> dict[str, Any]:
        """Return a dict matching the report Telemetry schema."""
        return {
            "round_trips": self.round_trips,
            "tokens": self.tokens,
            "duration_seconds": round(self.duration_seconds, 2),
            "tool_calls": self.tool_calls,
        }


# Module-level "current context" for simple use cases
_current: InstrumentationContext | None = None


def get_current_context() -> InstrumentationContext | None:
    """Return the active instrumentation context, if any."""
    return _current


@contextmanager
def instrumentation_context() -> Generator[InstrumentationContext, None, None]:
    """Context manager that provides and exposes an InstrumentationContext."""
    global _current
    ctx = InstrumentationContext()
    prev = _current
    _current = ctx
    try:
        yield ctx
    finally:
        _current = prev


def track_tool_call(fn: Callable) -> Callable:
    """Decorator that increments the active context's tool_calls counter."""

    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        ctx = get_current_context()
        if ctx:
            ctx.record_tool_call()
        return fn(*args, **kwargs)

    return wrapper
