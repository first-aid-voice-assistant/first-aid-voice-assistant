from app.providers.base import LLMDone, LLMOptions, LLMProvider, Message


async def complete(llm: LLMProvider, prompt: str, max_tokens: int) -> str:
    """A short side call that returns the whole answer at once (temperature 0).

    Used for classifying the user's words, not for answers the user reads or hears.
    """
    text = ""
    async for event in llm.generate_stream(
        [Message(role="user", content=prompt)], LLMOptions(temperature=0.0, max_tokens=max_tokens)
    ):
        if isinstance(event, LLMDone):
            text = event.text
    return text
