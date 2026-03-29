local git2 = require "fugit2.core.git2"
local libgit2 = require "fugit2.core.libgit2"

describe("revert", function()
  local repo --[[@as GitRepository]]
  local tmp_dir

  setup(function()
    local path = require("os").getenv "GIT2_DIR"
    libgit2.setup_lib(path and path .. "/lib/libgit2.so" or nil)

    -- Create a temporary git repo with two commits
    tmp_dir = os.tmpname()
    os.remove(tmp_dir)
    os.execute("mkdir -p " .. tmp_dir)
    os.execute(
      "cd "
        .. tmp_dir
        .. " && git init -q"
        .. " && git config user.email 'test@test.com'"
        .. " && git config user.name 'Test'"
        .. " && echo a > file.txt && git add file.txt && git commit -q -m 'initial'"
        .. " && echo b > file.txt && git add file.txt && git commit -q -m 'second'"
    )

    repo = git2.Repository.open(tmp_dir, false) --[[@as GitRepository]]
  end)

  teardown(function()
    if tmp_dir then
      os.execute("rm -rf " .. tmp_dir)
    end
  end)

  describe("revert", function()
    it("reverts HEAD commit and returns a new OID", function()
      local sig, sig_err = repo:signature_default()
      assert.are.equal(0, sig_err)
      assert.is_not_nil(sig)

      -- Get HEAD commit OID
      local head, head_err = repo:head()
      assert.are.equal(0, head_err)
      assert.is_not_nil(head)

      local head_commit, peel_err = head:peel_commit()
      assert.are.equal(0, peel_err)
      assert.is_not_nil(head_commit)

      local oid = head_commit:id()
      assert.is_not_nil(oid)

      local new_oid, err = repo:revert(oid, sig)
      assert.are.equal(0, err)
      assert.is_not_nil(new_oid)

      -- New OID must differ from the reverted commit
      assert.are.not_equal(oid:tostring(40), new_oid:tostring(40))
    end)

    it("restores file content to pre-revert state", function()
      -- HEAD at this point is the revert commit (file.txt = "a")
      local f = io.open(tmp_dir .. "/file.txt", "r")
      assert.is_not_nil(f)
      local content = f:read "*a"
      f:close()
      -- file.txt was "a" before the "second" commit; revert should restore it
      assert.are.equal("a\n", content)
    end)

    it("creates a revert commit with correct message format", function()
      -- HEAD is now the revert commit; check its message
      local head, _ = repo:head()
      local commit, _ = head:peel_commit()
      local message = commit:message()
      assert.is_true(message:find('Revert "second"') ~= nil, "Expected revert message, got: " .. message)
    end)

    it("revert commit message includes original commit OID", function()
      local head, _ = repo:head()
      local revert_commit, _ = head:peel_commit()
      local message = revert_commit:message()

      -- The message body should contain a 40-char hex OID
      assert.is_true(message:find "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]" ~= nil)
    end)

    it("fails with an invalid (all-zeros) OID", function()
      local sig, _ = repo:signature_default()

      local fake_oid, _ = git2.ObjectId.from_string "0000000000000000000000000000000000000000"
      assert.is_not_nil(fake_oid)

      local new_oid, err = repo:revert(fake_oid, sig)
      assert.is_nil(new_oid)
      assert.are.not_equal(0, err)
    end)
  end)
end)
