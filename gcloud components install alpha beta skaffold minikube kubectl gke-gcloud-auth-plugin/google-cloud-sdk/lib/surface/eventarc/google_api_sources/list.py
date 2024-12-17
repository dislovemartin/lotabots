# -*- coding: utf-8 -*- #
# Copyright 2024 Google LLC. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Command to list all Google API sources in a project and location."""

from __future__ import absolute_import
from __future__ import division
from __future__ import unicode_literals

from googlecloudsdk.api_lib.eventarc import google_api_sources
from googlecloudsdk.calliope import base
from googlecloudsdk.command_lib.eventarc import flags

_DETAILED_HELP = {
    "DESCRIPTION": "{description}",
    "EXAMPLES": """\
        To list all Google API sources in location ``us-central1'', run:

          $ {command} --location=us-central1

        To list all Google API sources in all locations, run:

          $ {command} --location=-

        or

          $ {command}
        """,
}

_FORMAT = """\
table(
    name.scope("googleApiSources"):label=NAME,
    destination.scope("messageBuses"):label=DESTINATION,
    destination.scope("projects").segment(1):label=DESTINATION_PROJECT,
    name.scope("locations").segment(0):label=LOCATION,
    loggingConfig.logSeverity:label=LOGGING_CONFIG
)
"""


@base.ReleaseTracks(base.ReleaseTrack.BETA)
@base.DefaultUniverseOnly
class List(base.ListCommand):
  """List Eventarc Google API sources."""

  detailed_help = _DETAILED_HELP

  @staticmethod
  def Args(parser):
    flags.AddLocationResourceArg(
        parser,
        "The location for which to list Google API sources. This should be one"
        " of the supported regions.",
        required=False,
        allow_aggregation=True,
    )
    flags.AddProjectResourceArg(parser)
    parser.display_info.AddFormat(_FORMAT)
    parser.display_info.AddUriFunc(google_api_sources.GetGoogleAPISourceURI)

  def Run(self, args):
    client = google_api_sources.GoogleApiSourceClientV1()
    location_ref = args.CONCEPTS.location.Parse()
    return client.List(location_ref, args.limit, args.page_size)
