defmodule SymphonyElixir.RecordingsTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.Recordings

  setup do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-recordings-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    {:ok, workspace_root: workspace_root}
  end

  defp recordings_dir!(workspace_root, issue_identifier) do
    dir = Path.join([workspace_root, issue_identifier, ".symphony", "recordings"])
    File.mkdir_p!(dir)
    dir
  end

  test "enabled? reflects container mode and the record flag" do
    refute Recordings.enabled?()

    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    refute Recordings.enabled?()

    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true, container_record: true)
    assert Recordings.enabled?()

    write_workflow_file!(Workflow.workflow_file_path(), container_engine: "lxc")
    refute Recordings.enabled?()
  end

  test "directory resolves under the issue workspace", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, dir} = Recordings.directory("MT-1")
    assert String.ends_with?(dir, Path.join(["MT-1", ".symphony", "recordings"]))
  end

  test "directory rejects an absolute recordings dir that lives only in the container",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      container_recordings_dir: "/var/recordings"
    )

    assert {:error, :recordings_dir_not_on_host} = Recordings.directory("MT-1")
  end

  test "list returns an empty list when nothing has been recorded yet",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, []} = Recordings.list("MT-2")
  end

  test "list returns recording files newest-first and ignores other files",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    dir = recordings_dir!(workspace_root, "MT-3")

    File.write!(Path.join(dir, "desktop-20260101-000000.mp4"), "aaa")
    File.write!(Path.join(dir, "desktop-20260101-000100.webm"), "bb")
    File.write!(Path.join(dir, "notes.txt"), "ignore me")

    assert {:ok, [first, second]} = Recordings.list("MT-3")
    assert first.name == "desktop-20260101-000100.webm"
    assert second.name == "desktop-20260101-000000.mp4"
    assert first.size == 2
    assert second.size == 3
    assert %DateTime{} = first.modified_at
  end

  test "list tolerates an unreadable recording entry", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    dir = recordings_dir!(workspace_root, "MT-3b")

    # A broken symlink is listed by File.ls but cannot be stat'd.
    File.ln_s!(Path.join(dir, "missing-target.mp4"), Path.join(dir, "broken.mp4"))

    assert {:ok, [recording]} = Recordings.list("MT-3b")
    assert recording.name == "broken.mp4"
    assert recording.size == 0
    assert recording.modified_at == nil
  end

  test "fetch returns the canonical path and content type for a recording",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    dir = recordings_dir!(workspace_root, "MT-4")
    File.write!(Path.join(dir, "desktop-20260101-000000.mp4"), "video")

    assert {:ok, %{path: path, content_type: "video/mp4"}} =
             Recordings.fetch("MT-4", "desktop-20260101-000000.mp4")

    assert File.read!(path) == "video"

    File.write!(Path.join(dir, "clip.webm"), "webm")
    assert {:ok, %{content_type: "video/webm"}} = Recordings.fetch("MT-4", "clip.webm")

    File.write!(Path.join(dir, "clip.mkv"), "mkv")
    assert {:ok, %{content_type: "video/x-matroska"}} = Recordings.fetch("MT-4", "clip.mkv")
  end

  test "fetch rejects traversal, separators, and non-recording names",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    recordings_dir!(workspace_root, "MT-5")

    assert {:error, :invalid_filename} = Recordings.fetch("MT-5", "")
    assert {:error, :invalid_filename} = Recordings.fetch("MT-5", "..")
    assert {:error, :invalid_filename} = Recordings.fetch("MT-5", "../secret.mp4")
    assert {:error, :invalid_filename} = Recordings.fetch("MT-5", "nested/clip.mp4")
    assert {:error, :invalid_filename} = Recordings.fetch("MT-5", "notes.txt")
  end

  test "fetch rejects a recording symlinked outside the recordings dir",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    dir = recordings_dir!(workspace_root, "MT-5b")

    outside = Path.join(workspace_root, "outside-secret.mp4")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(dir, "escape.mp4"))

    assert {:error, :path_outside_recordings_dir} = Recordings.fetch("MT-5b", "escape.mp4")
  end

  test "fetch reports missing files and rejects non-regular files",
       %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    dir = recordings_dir!(workspace_root, "MT-6")

    assert {:error, :enoent} = Recordings.fetch("MT-6", "missing.mp4")

    File.mkdir_p!(Path.join(dir, "directory.mp4"))
    assert {:error, :not_a_file} = Recordings.fetch("MT-6", "directory.mp4")
  end

  test "fetch surfaces an absolute recordings dir error", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      container_recordings_dir: "/var/recordings"
    )

    assert {:error, :recordings_dir_not_on_host} = Recordings.fetch("MT-7", "clip.mp4")
  end
end
