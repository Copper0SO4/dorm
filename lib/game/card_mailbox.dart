typedef CardMailboxRead = ({String revision, String body});

abstract interface class CardMailbox {
  Future<CardMailboxRead?> pull();
  Future<void> push(String body, String? revision);
}

class CardMailboxRace implements Exception {
  const CardMailboxRace();
}
