#!/usr/bin/env python3
# SOURCE: delivery.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-objets-runtime-v2.md §2 Delivery

REQUIRED_FIELDS = {
    "artifacts",
    "qualifierReport",
    "reviewerReport",
    "reviewerScore",
    "gatekeeperDecision",
    "gatekeeperJustification",
}


class InvalidDelivery(ValueError):
    pass


def validate_delivery(delivery_spec):
    """
    delivery_spec: dict (le contenu du champ 'spec' d une Delivery YAML)
    Raise InvalidDelivery si un invariant ne tient pas.
    """
    missing = REQUIRED_FIELDS - set(delivery_spec.keys())
    if missing:
        raise InvalidDelivery(f"missing required fields: {sorted(missing)}")

    # gatekeeperDecision = promote obligatoire (pas de Delivery si pas promo)
    d = delivery_spec["gatekeeperDecision"]
    if d != "promote":
        raise InvalidDelivery(
            f"gatekeeperDecision must be 'promote' (got {d!r} — "
            "no Delivery if not promoted)"
        )

    # reviewerScore int in [0, 10]
    score = delivery_spec["reviewerScore"]
    if not isinstance(score, int):
        raise InvalidDelivery(f"reviewerScore must be int, got {type(score).__name__}")
    if not (0 <= score <= 10):
        raise InvalidDelivery(f"reviewerScore must be in [0,10], got {score}")

    # artifacts non vide
    artifacts = delivery_spec["artifacts"]
    if not isinstance(artifacts, list) or len(artifacts) == 0:
        raise InvalidDelivery("artifacts must be a non-empty list")

    # gatekeeperJustification non vide
    j = delivery_spec["gatekeeperJustification"]
    if not isinstance(j, str) or not j.strip():
        raise InvalidDelivery("gatekeeperJustification must be a non-empty string")

    # reports non vides
    for key in ("qualifierReport", "reviewerReport"):
        v = delivery_spec[key]
        if not isinstance(v, str) or not v.strip():
            raise InvalidDelivery(f"{key} must be a non-empty string (path)")
