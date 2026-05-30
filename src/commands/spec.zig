pub const Command = struct {
    pub const help = "help";
    pub const space = "space";
    pub const project = "project";
    pub const task = "task";
    pub const sync = "sync";
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
    pub const link = "link";
    pub const linear = "linear";
    pub const github = "github";
    pub const trello = "trello";
};

pub const Flag = struct {
    pub const title = "--title";
    pub const priority = "--priority";
    pub const status = "--status";
    pub const due = "--due";
    pub const description = "--description";
    pub const notes = "--notes";

    pub const linear_key = "--linear-key";
    pub const linear_team = "--linear-team";
    pub const linear_project = "--linear-project";

    pub const github_token = "--github-token";
    pub const github_client_id = "--github-client-id";
    pub const github_owner = "--github-owner";
    pub const github_repo = "--github-repo";

    pub const trello_key = "--trello-key";
    pub const trello_token = "--trello-token";
    pub const trello_board = "--trello-board";
    pub const trello_list_todo = "--trello-list-todo";
    pub const trello_list_in_progress = "--trello-list-in-progress";
    pub const trello_list_in_review = "--trello-list-in-review";
    pub const trello_list_done = "--trello-list-done";
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
    \\Sync commands:
    \\  todo sync config  --linear-key KEY | --github-token TOKEN | --trello-key KEY --trello-token TOKEN
    \\  todo sync link    <space> <project> [--linear-team ID] [--linear-project ID]
    \\                                      [--github-owner O --github-repo R]
    \\                                      [--trello-board ID --trello-list-todo L ...]
    \\  todo sync linear  <space> <project>
    \\  todo sync github  <space> <project>
    \\  todo sync trello  <space> <project>
    \\
;
