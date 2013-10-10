require 'spec_helper'
require 'bosh/dev/promotable_artifacts'
require 'bosh/dev/build'

module Bosh::Dev
  describe PromotableArtifacts do
    subject(:build_artifacts) { PromotableArtifacts.new(build) }
    let(:build) { instance_double('Bosh::Dev::Build', number: 123) }

    its(:destination) { should eq('s3://bosh-jenkins-artifacts') }
    its(:source) { should eq('s3://bosh-ci-pipeline/123/') }
    its(:release_file) { should eq('bosh-123.tgz') }

    describe '#commands' do
      let(:stemcell_artifacts) { instance_double('Bosh::Dev::StemcellArtifacts', list: archive_filenames) }
      let(:archive_filenames) do
        [
          instance_double('Bosh::Stemcell::ArchiveFilename', to_s: 'blue/stemcell-blue.tgz'),
          instance_double('Bosh::Stemcell::ArchiveFilename', to_s: 'red/stemcell-red.tgz'),
        ]
      end

      before do
        stemcell_artifacts_klass = class_double('Bosh::Dev::StemcellArtifacts').as_stubbed_const
        stemcell_artifacts_klass.stub(:all).with(build.number).and_return(stemcell_artifacts)
        RakeFileUtils.stub(:sh)
      end

      it 'lists a command to promote the release' do
        RakeFileUtils.
          should_receive(:sh).
          with('s3cmd --verbose cp s3://bosh-ci-pipeline/123/release/bosh-123.tgz s3://bosh-jenkins-artifacts/release/bosh-123.tgz')

        build_artifacts.all.each { |artifact| artifact.promote }
      end

      it 'lists commands to promote gems' do
        RakeFileUtils.
          should_receive(:sh).
          with('s3cmd --verbose sync s3://bosh-ci-pipeline/123/gems/ s3://bosh-jenkins-gems')

        build_artifacts.all.each { |artifact| artifact.promote }
      end

      it 'lists commands to promote stemcell pipeline artifacts' do
        RakeFileUtils.
          should_receive(:sh).
          with('s3cmd --verbose cp s3://bosh-ci-pipeline/123/blue/stemcell-blue.tgz s3://bosh-jenkins-artifacts/blue/stemcell-blue.tgz')

        RakeFileUtils.
          should_receive(:sh).
          with('s3cmd --verbose cp s3://bosh-ci-pipeline/123/red/stemcell-red.tgz s3://bosh-jenkins-artifacts/red/stemcell-red.tgz')

        build_artifacts.all.each { |artifact| artifact.promote }
      end
    end
  end
end
