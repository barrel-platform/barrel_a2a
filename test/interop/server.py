"""A2A Python SDK server driven by the CT suite.

usage: server.py <port> [jsonrpc|rest|both]

Serves an agent whose behaviour mirrors barrel_a2a_test_agent for the
inputs the suite uses, over the official SDK's Starlette routes:

- ``echo: X``   working, artifact X, completed
- ``stream``    working, two artifact chunks (second appends), completed
- ``ask``       input_required; a follow-up on the same task completes
                with artifact ``thanks: <text>``
- ``direct``    a direct Message reply, no task
- ``slow N``    sleeps N ms, then completes with ``done``
- ``cancel-me`` working, then waits until cancelled

JSON-RPC is served at ``/a2a/jsonrpc`` and REST under ``/a2a/v1``; the
card at ``/.well-known/agent-card.json``. Prints ``READY <port>`` on
stdout once the listener is up.
"""

import asyncio
import contextlib
import sys

import uvicorn
from starlette.applications import Starlette

from a2a.helpers import (
    get_message_text,
    new_task_from_user_message,
    new_text_message,
    new_text_part,
)
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import (
    create_agent_card_routes,
    create_jsonrpc_routes,
    create_rest_routes,
)
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
    TaskState,
)

JSONRPC_PATH = '/a2a/jsonrpc'
REST_PREFIX = '/a2a/v1'


class TestAgentExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        text = get_message_text(context.message)
        current = context.current_task
        if current is not None and current.status.state == TaskState.TASK_STATE_INPUT_REQUIRED:
            updater = TaskUpdater(event_queue, current.id, current.context_id)
            await updater.add_artifact([new_text_part(f'thanks: {text}')])
            await updater.complete()
            return

        if text == 'direct':
            await event_queue.enqueue_event(
                new_text_message('direct reply', context_id=context.context_id)
            )
            return

        task = current or new_task_from_user_message(context.message)
        if current is None:
            await event_queue.enqueue_event(task)
        updater = TaskUpdater(event_queue, task.id, task.context_id)

        if text.startswith('echo: '):
            await updater.start_work()
            await updater.add_artifact([new_text_part(text[len('echo: '):])])
            await updater.complete()
        elif text == 'stream':
            await updater.start_work(updater.new_agent_message([new_text_part('starting')]))
            await updater.add_artifact([new_text_part('part one ')], artifact_id='a1', name='out')
            await updater.add_artifact(
                [new_text_part('part two')], artifact_id='a1', append=True, last_chunk=True
            )
            await updater.complete()
        elif text == 'ask':
            await updater.requires_input(updater.new_agent_message([new_text_part('more?')]))
        elif text.startswith('slow '):
            await updater.start_work()
            await asyncio.sleep(int(text[len('slow '):]) / 1000)
            await updater.add_artifact([new_text_part('done')])
            await updater.complete()
        elif text == 'cancel-me':
            await updater.start_work()
            await asyncio.Event().wait()
        else:
            await updater.start_work()
            await updater.add_artifact([new_text_part(f'unknown: {text}')])
            await updater.complete()

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        updater = TaskUpdater(event_queue, context.task_id, context.context_id or '')
        await updater.cancel()


def build_card(port: int, binding: str) -> AgentCard:
    base = f'http://127.0.0.1:{port}'
    interfaces = []
    if binding in ('jsonrpc', 'both'):
        interfaces.append(AgentInterface(
            url=base + JSONRPC_PATH, protocol_binding='JSONRPC', protocol_version='1.0'
        ))
    if binding in ('rest', 'both'):
        interfaces.append(AgentInterface(
            url=base + REST_PREFIX, protocol_binding='HTTP+JSON', protocol_version='1.0'
        ))
    return AgentCard(
        name='Python Test Agent',
        description='SDK agent mirroring barrel_a2a_test_agent',
        version='1.2.3',
        default_input_modes=['text/plain'],
        default_output_modes=['text/plain'],
        capabilities=AgentCapabilities(streaming=True),
        supported_interfaces=interfaces,
        skills=[AgentSkill(id='echo', name='Echo', description='Echoes text back', tags=['test'])],
    )


def build_app(port: int, binding: str) -> Starlette:
    card = build_card(port, binding)
    handler = DefaultRequestHandler(
        agent_executor=TestAgentExecutor(),
        task_store=InMemoryTaskStore(),
        agent_card=card,
    )
    routes = list(create_agent_card_routes(card))
    if binding in ('jsonrpc', 'both'):
        routes.extend(create_jsonrpc_routes(handler, JSONRPC_PATH))
    if binding in ('rest', 'both'):
        routes.extend(create_rest_routes(handler, path_prefix=REST_PREFIX))

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        yield
        await handler.aclose()

    return Starlette(routes=routes, lifespan=lifespan)


class ReadyServer(uvicorn.Server):
    def __init__(self, config: uvicorn.Config, port: int):
        super().__init__(config)
        self._port = port

    async def startup(self, sockets=None):
        await super().startup(sockets)
        sys.stdout.write(f'READY {self._port}\n')
        sys.stdout.flush()


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    port = int(argv[1])
    binding = argv[2] if len(argv) > 2 else 'both'
    if binding not in ('jsonrpc', 'rest', 'both'):
        sys.stderr.write(__doc__)
        return 2
    config = uvicorn.Config(
        build_app(port, binding), host='127.0.0.1', port=port, log_level='warning'
    )
    ReadyServer(config, port).run()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
