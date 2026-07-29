from html.parser import HTMLParser
from pathlib import Path


class PrototypeContract(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: set[str] = set()
        self.actions: set[str] = set()
        self.text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if value := values.get("id"):
            self.ids.add(value)
        if value := values.get("data-action"):
            self.actions.add(value)

    def handle_data(self, data: str) -> None:
        self.text.append(data)


html = Path(__file__).with_name("index.html").read_text(encoding="utf-8")
contract = PrototypeContract()
contract.feed(html)
visible_text = " ".join(contract.text)

required_ids = {
    "scenarioPicker",
    "providerSetup",
    "providerProgress",
    "comparisonScreen",
    "detailInspector",
    "livePopover",
    "emptyProviders",
    "manualFallback",
}
required_actions = {
    "toggle-theme",
    "select-scope",
    "toggle-provider",
    "run-analysis",
    "cancel-provider",
    "select-word",
    "filter-consensus",
    "create-rule",
    "copy-install",
    "show-manual",
}

assert required_ids <= contract.ids, required_ids - contract.ids
assert required_actions <= contract.actions, required_actions - contract.actions
assert "2 з 3 погодились" in visible_text
assert "EN layout → UK layout → spelling, 1 edit" in visible_text
assert "Ще 3 варіанти" in visible_text
assert "prefers-color-scheme" in html
assert "keydown" in html
assert "aria-live" in html

print("Prototype contract: OK")
