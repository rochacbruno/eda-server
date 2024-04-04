@Library(['aap-jenkins-shared-library@eda_hs_pipeline']) _
import steps.StepsFactory

stepsFactory = new StepsFactory(this, [:], 'integration')
Map provisionInfo = [:]
Map installInfo = [:]

pipeline {
    agent {
        kubernetes {
            yaml libraryResource('pod_templates/unpriv-ansible-pod.yaml')
        }
    }
    options {
        buildDiscarder(logRotator(daysToKeepStr: '10'))
        timeout(time: 12, unit: 'HOURS')
        timestamps()
    }

    stages {
        stage('Set branch variable') {
            steps {
                script {
                    sourceBranch = env.CHANGE_BRANCH
                    echo "Branch Name: ${sourceBranch}"
                }
            }
        }
        stage('Setup provisioner') {
            steps {
                container('aapqa-ansible') {
                    script {
                        stepsFactory.aapqaSetupSteps.setup([aapqaProvisionerBranch: 'eda_custom_container'])
                    }
                }
            }
        }
        stage('Provision') {
            steps {
                container('aapqa-ansible') {
                    script {
                        provisionInfo = stepsFactory.aapqaOnPremProvisionerSteps.init([
                            scenarioVarFile: "input/aap_scenarios/1inst_1hybr_1eda.yml",
                        ])
                        provisionInfo = stepsFactory.aapqaOnPremProvisionerSteps.provision(provisionInfo)
                    }
                }
            }
            post {
                always {
                    script {
                        stepsFactory.aapqaOnPremProvisionerSteps.archiveArtifacts()
                    }
                }
            }
        }

        stage('Containerized Install') {
            steps {
                container('aapqa-ansible') {
                    script {
                        stepsFactory.aapContainerizedInstallerSteps.updateBuildInformation(provisionInfo)
                        installInfo = stepsFactory.aapContainerizedInstallerSteps.install(provisionInfo + [
                                edaSourceBranch: sourceBranch,
                                installerVarFiles: ['input/install/flags/apply_license.yml'],
                        ])
                    }
                }
            }
            post {
                always {
                    script {
                        container('aapqa-ansible') {
                            stepsFactory.aapContainerizedInstallerSteps.collectAapInstallerArtifacts(provisionInfo + [
                                    archiveArtifactsSubdir: 'install'
                            ])
                        }
                    }
                }
            }
        }

        stage('Run tests') {
            steps {
                container('aapqa-ansible') {
                    script {

                        stepsFactory.aapqaEdaQaSteps.runApiTestSuite(installInfo + [
                                edaQaVars: ['eda_api_repo_version': 'main'],
                        ])
                        stepsFactory.commonSteps.saveXUnitResultsToJenkins(xunitFile: 'eda_api_results.xml')
                        stepsFactory.aapqaEdaQaSteps.reportTestResults(provisionInfo + installInfo +
                                [
                                    component: 'eda',
                                    testType: 'api',
                                ], "eda_api_results.xml")
                        stepsFactory.commonSteps.collectXUnitXmlFile("eda_api_results.xml")
                    }
                }
            }
        }

    }
    post {
        always {
            container('aapqa-ansible') {
                script {
                    stepsFactory.commonSteps.reportAllXUnitXmlFiles()
                    stepsFactory.aapqaAapInstallerSteps.generateAndCollectSosReports(provisionInfo)
                }
            }
        }
        cleanup {
            container('aapqa-ansible') {
                script {
                    stepsFactory.aapqaOnPremProvisionerSteps.cleanup(provisionInfo)
                }
            }
        }
    }
}
