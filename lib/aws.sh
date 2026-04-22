#!/usr/bin/env bash
# lib/aws.sh — shared AWS helpers
# Source this file; do not execute directly.
# Requires: S3_REGION (set in config.env), AWS_PROFILE (optional)

aws_cmd() {
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        aws --profile "${AWS_PROFILE}" --region "${S3_REGION}" "$@"
    else
        aws --region "${S3_REGION}" "$@"
    fi
}
