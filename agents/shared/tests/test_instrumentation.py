"""Unit tests for instrumentation module."""

import time

import pytest

from agents.shared.instrumentation import (
    InstrumentationContext,
    get_current_context,
    instrumentation_context,
    track_tool_call,
)


class TestInstrumentationContext:
    def test_initial_state(self):
        ctx = InstrumentationContext()
        assert ctx.tool_calls == 0
        assert ctx.tokens == 0
        assert ctx.round_trips == 0

    def test_record_tool_call(self):
        ctx = InstrumentationContext()
        ctx.record_tool_call()
        ctx.record_tool_call()
        assert ctx.tool_calls == 2

    def test_record_tokens(self):
        ctx = InstrumentationContext()
        ctx.record_tokens(1000)
        ctx.record_tokens(500)
        assert ctx.tokens == 1500

    def test_record_round_trip(self):
        ctx = InstrumentationContext()
        ctx.record_round_trip()
        assert ctx.round_trips == 1

    def test_duration_seconds(self):
        ctx = InstrumentationContext()
        time.sleep(0.05)
        assert ctx.duration_seconds >= 0.04  # Allow some tolerance

    def test_to_telemetry_dict(self):
        ctx = InstrumentationContext()
        ctx.record_tool_call()
        ctx.record_tokens(100)
        ctx.record_round_trip()

        result = ctx.to_telemetry_dict()
        assert result["tool_calls"] == 1
        assert result["tokens"] == 100
        assert result["round_trips"] == 1
        assert "duration_seconds" in result
        assert isinstance(result["duration_seconds"], float)


class TestContextManager:
    def test_context_manager_provides_context(self):
        with instrumentation_context() as ctx:
            assert ctx is not None
            assert get_current_context() is ctx

    def test_context_manager_restores_previous(self):
        assert get_current_context() is None
        with instrumentation_context():
            pass
        assert get_current_context() is None

    def test_nested_contexts(self):
        with instrumentation_context() as outer:
            outer.record_tool_call()
            with instrumentation_context() as inner:
                inner.record_tool_call()
                inner.record_tool_call()
                assert get_current_context() is inner
            assert get_current_context() is outer
        assert get_current_context() is None
        assert outer.tool_calls == 1
        assert inner.tool_calls == 2


class TestDecorator:
    def test_track_tool_call_increments_counter(self):
        @track_tool_call
        def my_tool():
            return "result"

        with instrumentation_context() as ctx:
            result = my_tool()
            assert result == "result"
            assert ctx.tool_calls == 1

    def test_track_tool_call_no_context(self):
        @track_tool_call
        def my_tool():
            return "ok"

        # Should not raise when no context is active
        result = my_tool()
        assert result == "ok"

    def test_track_tool_call_preserves_function_metadata(self):
        @track_tool_call
        def documented_tool():
            """This is documented."""
            pass

        assert documented_tool.__name__ == "documented_tool"
        assert documented_tool.__doc__ == "This is documented."
