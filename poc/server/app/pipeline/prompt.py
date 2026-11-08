from app.providers.base import Message


def build_prompt(
    system_prompt: str,
    history: list[Message],
    user_text: str,
    task: str | None = None,
) -> list[Message]:
    """System prompt, history and the new question.

    The current task of the guided conversation goes after the user's words, in the last
    message: small models follow it much better there than at the end of the system prompt,
    where they tend to copy earlier assistant messages from the history instead.
    """
    content = user_text if task is None else f"{user_text}\n\n{task}"
    return [
        Message(role="system", content=system_prompt),
        *history,
        Message(role="user", content=content),
    ]
