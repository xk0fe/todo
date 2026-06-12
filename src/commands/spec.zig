pub const Command = struct {
    pub const help = "help";
    pub const space = "space";
    pub const project = "project";
    pub const task = "task";
    pub const ext = "ext";
};

pub const HelpFlag = struct {
    pub const long = "--help";
    pub const short = "-h";
};

pub const Subcommand = struct {
    pub const add = "add";
    pub const list = "list";
    pub const ls = "ls";
    pub const rm = "rm";
    pub const remove = "remove";
    pub const done = "done";
    pub const edit = "edit";
    pub const config = "config";
    pub const setup = "setup";
    pub const link = "link";
    pub const unlink = "unlink";
    pub const import = "import";
    pub const @"export" = "export";
};

pub const Flag = struct {
    pub const title = "--title";
    pub const priority = "--priority";
    pub const status = "--status";
    pub const due = "--due";
    pub const description = "--description";
    pub const notes = "--notes";
};

pub const task_filter_all = "all";

pub const usage =
    \\Usage: todo <command> [args]
    \\
    \\Space commands:
    \\  todo space add <name>
    \\  todo space list
    \\  todo space rm <name>
    \\
    \\Project commands:
    \\  todo project add <space> <name>
    \\  todo project list <space>
    \\  todo project rm <space> <name>
    \\
    \\Task commands:
    \\  todo task add <space> <project> <title> [--priority high|medium|low] [--due DATE] [--notes TEXT]
    \\  todo task list <space> <project> [--status todo|in-progress|done|all]
    \\  todo task done <space> <project> <id>
    \\  todo task edit <space> <project> <id> [--title X] [--priority X] [--status X] [--due X] [--notes X]
    \\  todo task rm <space> <project> <id>
    \\
    \\Extension commands (extensions are executables in ~/.todo/extensions):
    \\  todo ext list                                    show installed extensions
    \\  todo ext config <name> [key=value ...]           show or set global extension config
    \\  todo ext setup  <name>                           run the extension's interactive setup
    \\  todo ext link   <space> <project> <name> [key=value ...]
    \\  todo ext unlink <space> <project>
    \\  todo ext import <space> <project>                pull tasks from the linked extension
    \\  todo ext export <space> <project>                push tasks to the linked extension
    \\
;
