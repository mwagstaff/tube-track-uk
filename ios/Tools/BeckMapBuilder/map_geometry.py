"""Shared deterministic geometry measurements for Beck-map authoring tools."""

from __future__ import annotations

import math
from typing import Any


Point = tuple[float, float]


def point(value: dict[str, Any]) -> Point:
    return float(value["x"]), float(value["y"])


def command_point(command: dict[str, Any], key: str = "to") -> Point:
    return point(command[key])


def translated(value: Point, translation: dict[str, Any]) -> Point:
    return value[0] + float(translation["x"]), value[1] + float(translation["y"])


def distance(left: Point, right: Point) -> float:
    return math.hypot(left[0] - right[0], left[1] - right[1])


def midpoint(left: Point, right: Point) -> Point:
    return (left[0] + right[0]) / 2, (left[1] + right[1]) / 2


def acute_angle(left: Point, right: Point) -> float:
    left_length = math.hypot(*left)
    right_length = math.hypot(*right)
    if left_length <= 1e-9 or right_length <= 1e-9:
        return 0.0
    cosine = abs((left[0] * right[0] + left[1] * right[1]) / (left_length * right_length))
    return math.degrees(math.acos(min(1.0, max(-1.0, cosine))))


def lerp(left: Point, right: Point, fraction: float) -> Point:
    return (
        left[0] + (right[0] - left[0]) * fraction,
        left[1] + (right[1] - left[1]) * fraction,
    )


def cubic_point(
    start: Point, control1: Point, control2: Point, end: Point, fraction: float,
) -> Point:
    inverse = 1.0 - fraction
    return (
        inverse**3 * start[0]
        + 3 * inverse * inverse * fraction * control1[0]
        + 3 * inverse * fraction * fraction * control2[0]
        + fraction**3 * end[0],
        inverse**3 * start[1]
        + 3 * inverse * inverse * fraction * control1[1]
        + 3 * inverse * fraction * fraction * control2[1]
        + fraction**3 * end[1],
    )


def cubic_tangent(
    start: Point, control1: Point, control2: Point, end: Point, fraction: float,
) -> Point:
    inverse = 1.0 - fraction
    return (
        3 * inverse * inverse * (control1[0] - start[0])
        + 6 * inverse * fraction * (control2[0] - control1[0])
        + 3 * fraction * fraction * (end[0] - control2[0]),
        3 * inverse * inverse * (control1[1] - start[1])
        + 6 * inverse * fraction * (control2[1] - control1[1])
        + 3 * fraction * fraction * (end[1] - control2[1]),
    )


def nearest_on_line(target: Point, start: Point, end: Point) -> tuple[float, Point, Point]:
    tangent = end[0] - start[0], end[1] - start[1]
    length_squared = tangent[0] ** 2 + tangent[1] ** 2
    if length_squared <= 1e-12:
        return distance(target, start), start, tangent
    fraction = max(0.0, min(1.0, (
        (target[0] - start[0]) * tangent[0]
        + (target[1] - start[1]) * tangent[1]
    ) / length_squared))
    candidate = lerp(start, end, fraction)
    return distance(target, candidate), candidate, tangent


def nearest_on_cubic(
    target: Point, start: Point, control1: Point, control2: Point, end: Point,
) -> tuple[float, Point, Point]:
    # TfL curves are smooth and short. Dense deterministic sampling followed
    # by local refinement is stable and accurate at the audit's one-unit scale.
    samples = 128
    best_index = min(
        range(samples + 1),
        key=lambda index: distance(
            target, cubic_point(start, control1, control2, end, index / samples)
        ),
    )
    lower = max(0.0, (best_index - 1) / samples)
    upper = min(1.0, (best_index + 1) / samples)
    for _ in range(24):
        first = lower + (upper - lower) / 3
        second = upper - (upper - lower) / 3
        first_distance = distance(target, cubic_point(start, control1, control2, end, first))
        second_distance = distance(target, cubic_point(start, control1, control2, end, second))
        if first_distance <= second_distance:
            upper = second
        else:
            lower = first
    fraction = (lower + upper) / 2
    candidate = cubic_point(start, control1, control2, end, fraction)
    return (
        distance(target, candidate),
        candidate,
        cubic_tangent(start, control1, control2, end, fraction),
    )
