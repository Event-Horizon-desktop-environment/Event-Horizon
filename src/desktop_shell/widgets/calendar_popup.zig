const std = @import("std");

pub const Model = struct {
    year: i32 = 2026,
    month: u8 = 10,
    today_year: i32 = 2026,
    today_month: u8 = 10,
    today_day: u8 = 7,

    pub fn nextMonth(self: *Model) void {
        if (self.month == 12) {
            self.month = 1;
            self.year += 1;
        } else {
            self.month += 1;
        }
    }

    pub fn prevMonth(self: *Model) void {
        if (self.month == 1) {
            self.month = 12;
            self.year -= 1;
        } else {
            self.month -= 1;
        }
    }

    pub fn isToday(self: *const Model, day: u8) bool {
        return self.year == self.today_year and self.month == self.today_month and day == self.today_day;
    }
};

test "calendar-popup: nav + today" {
    const t = std.testing;
    var m = Model{};
    try t.expect(m.isToday(7));
    try t.expect(!m.isToday(8));
    m.nextMonth();
    try t.expect(m.month == 11);
    m.prevMonth();
    m.prevMonth();
    try t.expect(m.month == 9);
}
