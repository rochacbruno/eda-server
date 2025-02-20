#  Copyright 2023 Red Hat, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
import logging
import typing as tp

import yaml
from django.conf import settings
from rest_framework import serializers

from aap_eda.core import enums, models
from aap_eda.core.utils.credentials import validate_schema
from aap_eda.core.utils.k8s_service_name import is_rfc_1035_compliant

logger = logging.getLogger(__name__)

NOT_ACCEPTABLE_TYPES_FOR_ACTIVATION = [
    enums.DefaultCredentialType.REGISTRY,
    enums.DefaultCredentialType.GPG,
    enums.DefaultCredentialType.SOURCE_CONTROL,
]


def check_if_rulebook_exists(rulebook_id: int) -> int:
    try:
        models.Rulebook.objects.get(pk=rulebook_id)
    except models.Rulebook.DoesNotExist:
        raise serializers.ValidationError(
            f"Rulebook with id {rulebook_id} does not exist"
        )
    return rulebook_id


def check_if_de_exists(decision_environment_id: int) -> int:
    try:
        de = models.DecisionEnvironment.objects.get(pk=decision_environment_id)
        if de.eda_credential_id:
            models.EdaCredential.objects.get(pk=de.eda_credential_id)
    except models.EdaCredential.DoesNotExist:
        raise serializers.ValidationError(
            f"EdaCredential with id {de.eda_credential_id} does not exist"
        )
    except models.DecisionEnvironment.DoesNotExist:
        raise serializers.ValidationError(
            f"DecisionEnvironment with id {decision_environment_id} "
            "does not exist"
        )
    return decision_environment_id


def get_credential_if_exists(eda_credential_id: int) -> models.EdaCredential:
    try:
        return models.EdaCredential.objects.get(pk=eda_credential_id)
    except models.EdaCredential.DoesNotExist:
        raise serializers.ValidationError(
            f"EdaCredential with id {eda_credential_id} does not exist"
        )


def check_credential_types_for_activation(eda_credential_id: int) -> int:
    check_credential_types(
        eda_credential_id,
        types=NOT_ACCEPTABLE_TYPES_FOR_ACTIVATION,
        negative=True,
    )

    return eda_credential_id


def check_credential_types_for_registry(eda_credential_id: int) -> int:
    check_credential_types(
        eda_credential_id, [enums.DefaultCredentialType.REGISTRY]
    )

    return eda_credential_id


def check_credential_types_for_gpg(eda_credential_id: int) -> int:
    check_credential_types(
        eda_credential_id, [enums.DefaultCredentialType.GPG]
    )

    return eda_credential_id


def check_credential_types_for_scm(eda_credential_id: int) -> int:
    check_credential_types(
        eda_credential_id,
        [enums.DefaultCredentialType.SOURCE_CONTROL],
    )

    return eda_credential_id


def check_multiple_credentials(eda_credential_ids: list[int]) -> int:
    for eda_credential_id in eda_credential_ids:
        check_credential_types_for_activation(eda_credential_id)

    return eda_credential_ids


def check_if_credential_type_exists(credential_type_id: int) -> int:
    try:
        models.CredentialType.objects.get(pk=credential_type_id)
    except models.CredentialType.DoesNotExist:
        raise serializers.ValidationError(
            f"CredentialType with id {credential_type_id} does not exist"
        )
    return credential_type_id


def check_if_organization_exists(organization_id: int) -> int:
    try:
        models.Organization.objects.get(pk=organization_id)
    except models.Organization.DoesNotExist:
        raise serializers.ValidationError(
            f"Organization with id {organization_id} does not exist"
        )
    return organization_id


def check_if_extra_var_exists(extra_var_id: int) -> int:
    try:
        models.ExtraVar.objects.get(pk=extra_var_id)
    except models.ExtraVar.DoesNotExist:
        raise serializers.ValidationError(
            f"ExtraVar with id {extra_var_id} does not exist"
        )
    return extra_var_id


def check_if_awx_token_exists(awx_token_id: int) -> int:
    try:
        models.AwxToken.objects.get(pk=awx_token_id)
    except models.AwxToken.DoesNotExist:
        raise serializers.ValidationError(
            f"AwxToken with id {awx_token_id} does not exist"
        )
    return awx_token_id


def check_rulesets_require_token(
    rulesets_data: list[dict[str, tp.Any]],
) -> bool:
    """Inspect rulesets data to determine if a token is required.

    Return True if any of the rules has an action that requires a token.
    """
    required_actions = {"run_job_template", "run_workflow_template"}

    for ruleset in rulesets_data:
        for rule in ruleset.get("rules", []):
            # When it is a single action dict
            if any(
                action_key in required_actions
                for action_key in rule.get("action", {})
            ):
                return True

            # When it is a list of actions
            if any(
                action_arg in required_actions
                for action in rule.get("actions", [])
                for action_arg in action
            ):
                return True

    return False


def is_extra_var_dict(extra_var: str):
    try:
        data = yaml.safe_load(extra_var)
        if not isinstance(data, dict):
            raise serializers.ValidationError(
                "Extra var is not in object format"
            )
    except yaml.YAMLError:
        raise serializers.ValidationError(
            "Extra var must be in JSON or YAML format"
        )


def check_if_event_streams_exists(event_stream_ids: list[int]) -> list[int]:
    for event_stream_id in event_stream_ids:
        try:
            models.EventStream.objects.get(pk=event_stream_id)
        except models.EventStream.DoesNotExist:
            raise serializers.ValidationError(
                f"EventStream with id {event_stream_id} does not exist"
            )
    return event_stream_ids


def check_if_schema_valid(schema: dict):
    errors = validate_schema(schema)

    if bool(errors):
        raise serializers.ValidationError(errors)


def check_if_rfc_1035_compliant(service_name: str):
    if settings.DEPLOYMENT_TYPE == "k8s" and not is_rfc_1035_compliant(
        service_name
    ):
        raise serializers.ValidationError(
            f"{service_name} must be a valid RFC 1035 label name"
        )


def check_credential_types(
    eda_credential_id: int,
    types: list[enums.DefaultCredentialType],
    negative: bool = False,
) -> None:
    credential = get_credential_if_exists(eda_credential_id)
    name = credential.credential_type.name

    names = [ctype.value for ctype in types]
    if negative and name in names:
        raise serializers.ValidationError(
            f"The type of credential can not be one of {names}"
        )
    if not negative and name not in names:
        raise serializers.ValidationError(
            f"The type of credential can only be one of {names}"
        )
