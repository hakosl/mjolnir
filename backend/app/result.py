"""
Result monad for explicit error handling without exceptions.

Instead of raising exceptions that bubble up unpredictably, every operation
returns either Ok(value) or Err(reason). This forces callers to handle
both paths and makes error flow visible in the type signature.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Generic, TypeVar, Union

T = TypeVar("T")
E = TypeVar("E")


@dataclass(frozen=True, slots=True)
class Ok(Generic[T]):
    value: T

    @property
    def is_ok(self) -> bool:
        return True

    @property
    def is_err(self) -> bool:
        return False


@dataclass(frozen=True, slots=True)
class Err(Generic[E]):
    reason: E

    @property
    def is_ok(self) -> bool:
        return False

    @property
    def is_err(self) -> bool:
        return True


Result = Union[Ok[T], Err[E]]
