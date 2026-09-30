"""Real `by llm()` call sites for the System One lowering tests.

The lowering reads what the compiler recorded, so the declarations have to be
compiled ones. Tests swap `llm` for a probe and call these.
"""
import from jaclang.byllm.lib { Model }

glob llm = Model(model_name="mockllm");


"""How urgently a support ticket needs a human."""
enum Priority { LOW, HIGH }

sem Priority.LOW = "can wait until the next business day";
sem Priority.HIGH = "needs attention right now";


enum Team { BILLING, SECURITY, PLATFORM }


def rank(ticket: str) -> Priority by llm();
sem rank = "Rank how urgent the ticket is";


def route(subject: str, body: str) -> Team by llm();


def is_spam(subject: str) -> bool by llm();
sem is_spam = "True if this message is unsolicited bulk mail";


def summarize(text: str) -> str by llm();
