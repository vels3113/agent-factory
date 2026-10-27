#!/usr/bin/env bash
# Stub ctest: logs the call to $STUB_CMAKE_LOG.
echo "ctest $*" >> "$STUB_CMAKE_LOG"
