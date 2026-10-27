#!/usr/bin/env bash
# Stands in for a build tool the plugin wraps: prints the variables the plugin
# sets, exits with STUB_BUILD_EXIT (default 0).
echo "building with PLUGIN_TEST_ENV=$PLUGIN_TEST_ENV PATH=$PATH"
exit "${STUB_BUILD_EXIT:-0}"
