#!/usr/bin/env ruby
# Check the release job graph, not a duplicate publishing implementation.
require "yaml"
require "minitest/autorun"

WORKFLOW = YAML.load_file(ARGV.shift || ".github/workflows/release.yml")

class ReleaseWorkflowContract < Minitest::Test
  def setup
    @jobs = WORKFLOW.fetch("jobs")
    @publisher_id, @publisher = @jobs.find do |_, job|
      job.fetch("steps").any? { |step| step.fetch("uses", "").start_with?("softprops/action-gh-release@") }
    end
    refute_nil @publisher, "the workflow must publish a release"
  end

  def test_publish_waits_for_both_build_and_macos_26_verification
    build = @jobs.fetch("build")
    verification = @jobs.fetch("verify-macos-26")
    assert_equal "xcode-27", build.fetch("runs-on")
    assert_equal "macos-26", verification.fetch("runs-on")
    assert_includes Array(verification.fetch("needs")), "build"
    assert_includes Array(@publisher.fetch("needs")), "build"
    assert_includes Array(@publisher.fetch("needs")), "verify-macos-26"
    refute @publisher.key?("if"), "publish must not bypass a failed verification"
    refute verification.key?("if"), "verification must not bypass a failed build"
    assert_equal "read", WORKFLOW.fetch("permissions").fetch("contents")
    assert_equal "write", @publisher.fetch("permissions").fetch("contents")
  end

  def test_verification_and_publish_consume_the_same_packaged_artifact
    upload = @jobs.fetch("build").fetch("steps").find do |step|
      step.fetch("uses", "").start_with?("actions/upload-artifact@")
    end
    refute_nil upload
    artifact_name = upload.fetch("with").fetch("name")
    [@jobs.fetch("verify-macos-26"), @publisher].each do |job|
      download = job.fetch("steps").find do |step|
        step.fetch("uses", "").start_with?("actions/download-artifact@")
      end
      refute_nil download
      assert_equal artifact_name, download.fetch("with").fetch("name")
      refute job.fetch("steps").any? { |step| step.fetch("run", "").include?("swift build") },
             "verification and publishing must not rebuild the binary"
    end
    commands = @jobs.fetch("verify-macos-26").fetch("steps").map { |step| step.fetch("run", "") }.join("\n")
    assert_includes commands, "shasum -a 256 -c"
    assert_includes commands, "tar -xzf"
    assert_includes commands, "codesign --verify --strict"
    assert_includes commands, "release-binary-launch-smoke.sh verify/macvis"
  end
end
