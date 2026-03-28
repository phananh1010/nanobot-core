from nanobot.bus.events import InboundMessage
from nanobot.agent.loop import AgentLoop

async def on_progress(content: str, *, tool_hint: bool = False) -> None:
    print(("tool_hint" if tool_hint else "progress") + ":", content)


async def main():
    channel: str = "cli"
    chat_id: str = "direct"
    #message = "find nearest walmart to inspire nail bar in nova, virginia"
    content = "find nearest walmart to inspire nail bar in nova, virginia"
    session_key = f"{channel}:{chat_id}" #for example: cli:test
    session = agent.sessions.get_or_create(key)
    msg = InboundMessage(channel=channel, sender_id="user", chat_id=chat_id, content=content)
    response = await agent._process_message(msg, session_key=session_key, on_progress=on_progress)
    print(response.content)


if __name__ == "__main__":
    main()
