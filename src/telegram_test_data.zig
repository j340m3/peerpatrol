// Test fixtures for telegram.zig — Bot API response snippets.

pub const ok_true =
    \\{"ok":true,"result":{"message_id":9,"date":0,"chat":{"id":100,"type":"group"},"text":"DOWN web @bucket 5"}}
;

pub const ok_false =
    \\{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}
;
