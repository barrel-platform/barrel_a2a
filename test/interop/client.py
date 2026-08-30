"""A2A Python SDK client driven by the CT suite.

usage: client.py <base_url> <jsonrpc|rest> <scenario>

Resolves the Agent Card at ``<base_url>/.well-known/agent-card.json``,
builds a client over the requested binding and runs one scenario
against barrel_a2a_test_agent. Every step prints one JSON object per
line on stdout; the Erlang side asserts on those. Exit code 0 means
the scenario ran to the end.
"""

import asyncio
import json
import sys
import traceback

from a2a.client import ClientConfig, ClientFactory
from a2a.helpers import get_artifact_text, get_message_text, new_text_message
from a2a.types import (
    CancelTaskRequest,
    GetTaskRequest,
    Role,
    SendMessageConfiguration,
    SendMessageRequest,
    TaskState,
)
from a2a.utils.constants import TransportProtocol

BINDINGS = {
    'jsonrpc': TransportProtocol.JSONRPC,
    'rest': TransportProtocol.HTTP_JSON,
}


def emit(**fields):
    sys.stdout.write(json.dumps(fields) + '\n')
    sys.stdout.flush()


def state_name(state):
    return TaskState.Name(state)


def artifact_text(task):
    return ''.join(get_artifact_text(a, delimiter='') for a in task.artifacts)


def user_message(text, task_id=None, context_id=None):
    return new_text_message(
        text, task_id=task_id, context_id=context_id, role=Role.ROLE_USER
    )


def make_client(base_url, binding, streaming=True, polling=False):
    config = ClientConfig(
        streaming=streaming,
        polling=polling,
        supported_protocol_bindings=[BINDINGS[binding]],
        use_client_preference=True,
    )
    return ClientFactory(config)


def event_kind(event):
    return event.WhichOneof(event.DESCRIPTOR.oneofs[0].name) or 'empty'


async def consume(client, request):
    """Drain send_message; return (kind_list, last_task, direct_message)."""
    kinds = []
    task = None
    message = None
    async for event in client.send_message(request):
        kind = event_kind(event)
        kinds.append(kind)
        if kind == 'task':
            task = event.task
        elif kind == 'message':
            message = event.message
        elif kind == 'status_update' and task is not None:
            task.status.CopyFrom(event.status_update.status)
        elif kind == 'artifact_update' and task is not None:
            upd = event.artifact_update
            existing = None
            for a in task.artifacts:
                if a.artifact_id == upd.artifact.artifact_id:
                    existing = a
            if existing is not None and upd.append:
                existing.parts.extend(upd.artifact.parts)
            elif existing is not None:
                existing.CopyFrom(upd.artifact)
            else:
                task.artifacts.append(upd.artifact)
    return kinds, task, message


async def scenario_card(base_url, binding):
    factory = make_client(base_url, binding)
    client = await factory.create_from_url(base_url)
    card = client._card
    emit(
        step='card',
        name=card.name,
        skills=len(card.skills),
        streaming=card.capabilities.streaming,
        interfaces=[
            {'binding': i.protocol_binding, 'url': i.url, 'version': i.protocol_version}
            for i in card.supported_interfaces
        ],
    )
    await client.close()


async def scenario_send(base_url, binding):
    factory = make_client(base_url, binding, streaming=False)
    client = await factory.create_from_url(base_url)
    kinds, task, _ = await consume(client, SendMessageRequest(
        message=user_message('echo: from python')
    ))
    emit(step='send', kinds=kinds, state=state_name(task.status.state),
         artifact=artifact_text(task), task_id=task.id, context_id=task.context_id)
    await client.close()


async def scenario_stream(base_url, binding):
    factory = make_client(base_url, binding, streaming=True)
    client = await factory.create_from_url(base_url)
    events = []
    task = None
    async for event in client.send_message(SendMessageRequest(
        message=user_message('stream')
    )):
        kind = event_kind(event)
        entry = {'kind': kind}
        if kind == 'task':
            task = event.task
            entry['state'] = state_name(task.status.state)
        elif kind == 'status_update':
            entry['state'] = state_name(event.status_update.status.state)
            entry['final'] = event.status_update.status.state in (
                TaskState.TASK_STATE_COMPLETED,
                TaskState.TASK_STATE_FAILED,
                TaskState.TASK_STATE_CANCELED,
                TaskState.TASK_STATE_REJECTED,
            )
        elif kind == 'artifact_update':
            upd = event.artifact_update
            entry['append'] = upd.append
            entry['last_chunk'] = upd.last_chunk
            entry['text'] = get_artifact_text(upd.artifact, delimiter='')
        events.append(entry)
        emit(step='event', **entry)
    final = [e for e in events if e['kind'] == 'status_update'][-1]
    emit(step='stream', kinds=[e['kind'] for e in events], state=final['state'],
         task_id=task.id if task else None)
    await client.close()


async def scenario_multiturn(base_url, binding):
    factory = make_client(base_url, binding, streaming=False)
    client = await factory.create_from_url(base_url)
    _, task, _ = await consume(client, SendMessageRequest(
        message=user_message('ask')
    ))
    emit(step='ask', state=state_name(task.status.state),
         prompt=get_message_text(task.status.message), task_id=task.id,
         context_id=task.context_id)
    _, done, _ = await consume(client, SendMessageRequest(
        message=user_message('second', task_id=task.id, context_id=task.context_id)
    ))
    emit(step='multiturn', state=state_name(done.status.state),
         artifact=artifact_text(done), same_task=done.id == task.id,
         history=len(done.history))
    await client.close()


async def scenario_cancel(base_url, binding):
    factory = make_client(base_url, binding, streaming=False, polling=True)
    client = await factory.create_from_url(base_url)
    _, task, _ = await consume(client, SendMessageRequest(
        message=user_message('cancel-me'),
        configuration=SendMessageConfiguration(return_immediately=True),
    ))
    emit(step='started', state=state_name(task.status.state), task_id=task.id)
    canceled = await client.cancel_task(CancelTaskRequest(id=task.id))
    emit(step='cancel', state=state_name(canceled.status.state), task_id=canceled.id)
    fetched = await client.get_task(GetTaskRequest(id=task.id))
    emit(step='after_cancel', state=state_name(fetched.status.state))
    await client.close()


async def scenario_direct(base_url, binding):
    factory = make_client(base_url, binding, streaming=False)
    client = await factory.create_from_url(base_url)
    kinds, _, message = await consume(client, SendMessageRequest(
        message=user_message('direct')
    ))
    emit(step='direct', kinds=kinds, text=get_message_text(message),
         role=Role.Name(message.role))
    await client.close()


async def scenario_get(base_url, binding):
    factory = make_client(base_url, binding, streaming=False)
    client = await factory.create_from_url(base_url)
    _, task, _ = await consume(client, SendMessageRequest(
        message=user_message('echo: x')
    ))
    fetched = await client.get_task(GetTaskRequest(id=task.id))
    emit(step='get', state=state_name(fetched.status.state), task_id=fetched.id,
         same_id=fetched.id == task.id, artifact=artifact_text(fetched),
         history=len(fetched.history))
    await client.close()


SCENARIOS = {
    'card': scenario_card,
    'send': scenario_send,
    'stream': scenario_stream,
    'multiturn': scenario_multiturn,
    'cancel': scenario_cancel,
    'direct': scenario_direct,
    'get': scenario_get,
}


async def main(argv):
    if len(argv) != 4 or argv[2] not in BINDINGS or argv[3] not in SCENARIOS:
        sys.stderr.write(__doc__)
        return 2
    base_url, binding, scenario = argv[1], argv[2], argv[3]
    try:
        await asyncio.wait_for(SCENARIOS[scenario](base_url, binding), timeout=40)
    except Exception as exc:  # noqa: BLE001
        traceback.print_exc()
        emit(step='error', error=repr(exc))
        return 1
    emit(step='done')
    return 0


if __name__ == '__main__':
    sys.exit(asyncio.run(main(sys.argv)))
