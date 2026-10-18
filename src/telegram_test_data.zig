// Test fixtures for telegram.zig — Bot API response snippets.
pub const sample_updates =
    \\{"ok":true,"result":[
    \\ {"update_id":1,"message":{"message_id":1,"from":{"id":7,"is_bot":true},"chat":{"id":100,"type":"group"},"date":1700000001,"text":"UP web"}},
    \\ {"update_id":2,"message":{"message_id":2,"from":{"id":7,"is_bot":false},"chat":{"id":100,"type":"group"},"date":1700000002,"text":"https://example.com looks broken"}},
    \\ {"update_id":3,"message":{"message_id":3,"from":{"id":7,"is_bot":false},"chat":{"id":100,"type":"group"},"date":1700000003,"text":"hello world"}}
    \\ ]}
;

pub const ok_true =
    \\{"ok":true,"result":{"message_id":9,"date":0,"chat":{"id":100,"type":"group"},"text":"DOWN web @bucket 5"}}
;

pub const ok_false =
    \\{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}
;
