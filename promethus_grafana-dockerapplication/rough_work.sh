pipeline {
    agent any
    
    environment {
        JMETER_HOME = '/opt/apache-jmeter-5.6.3'
        PATH = "${JMETER_HOME}/bin:${env.PATH}"
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    try {
                        git branch: 'main', credentialsId: 'gitlab-login', url: 'https://gitlab.com/practice-group9221502/cicd-project.git'
                    } catch (Exception e) {
                        echo "Error during checkout: ${e.getMessage()}"
                        currentBuild.result = 'FAILURE'
                        error("Stopping pipeline due to checkout failure")
                    }
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                script {
                    try {
                        withCredentials([string(credentialsId: 'sonar_qube_token', variable: 'SONAR_TOKEN')]) {
                            sh '''
                                /opt/sonar-scanner-5.0.1.3006-linux/bin/sonar-scanner \
                                -Dsonar.projectKey=cicd-project \
                                -Dsonar.sources=. \
                                -Dsonar.host.url=http://10.18.22.18:9001/ \
                                -Dsonar.login=$SONAR_TOKEN
                            '''
                        }
                    } catch (Exception e) {
                        echo "Error during SonarQube analysis: ${e.getMessage()}"
                        currentBuild.result = 'FAILURE'
                        error("Stopping pipeline due to SonarQube analysis failure")
                    }
                }
            }
        }

        stage('Containerizing PHP Application') {
            steps {
                script {
                    try {
                        echo 'Building Docker image for PHP application...'
                        sh 'sudo docker build -t docker.mnserviceproviders.com/php_hellow:v1 .'
                    } catch (Exception e) {
                        echo "Error during Docker build: ${e.getMessage()}"
                        currentBuild.result = 'FAILURE'
                        error("Stopping pipeline due to Docker build failure")
                    }
                }
            }
        }

        stage('Run API Tests') {
            steps {
                script {
                    catchError(buildResult: 'SUCCESS', stageResult: 'FAILURE') {
                        sh 'newman run /var/jenkins_home/workspace/$JOB_NAME/mmdev2api.postman_collection__1_.json -r htmlextra'
                    }
                }
            }
            post {
                always {
                    script {
                        try {
                            sh 'cp /var/jenkins_home/workspace/cicd-project/newman/*.html /tmp/'

                            def htmlReportsDir = "/tmp/"
                            def htmlReports = sh(script: 'ls /tmp/*.html', returnStdout: true).trim().split('\n')

                            htmlReports.each { reportFile ->
                                def reportName = reportFile.tokenize('/').last()
                                def reportContent = readFile(file: reportFile).trim()
                                storeReportInDatabase(reportName, reportContent)
                            }
                        } catch (Exception e) {
                            echo "Error during API tests post-processing: ${e.getMessage()}"
                        }
                    }
                }
            }
        }
        
        stage('Verify JMeter Version') {
            steps {
                script {
                    sh "jmeter -v"
                }
            }
        }

        stage('Run JMeter Tests') {
            steps {
                script {
                    try {
                        sh '''
                            mkdir -p /var/jenkins_home/workspace/cicd-project/jmeter_folder/csv
                            mkdir -p /var/jenkins_home/workspace/cicd-project/jmeter_folder/html
                            rm -rf /var/jenkins_home/workspace/cicd-project/jmeter_folder/csv/*
                            rm -rf /var/jenkins_home/workspace/cicd-project/jmeter_folder/html/*
                        '''

                        sh '''
                           jmeter -n -t /var/jenkins_home/workspace/cicd-project/wikipedia.jmx -l /var/jenkins_home/workspace/cicd-project/jmeter_folder/csv/wikipedia.csv -e -o /var/jenkins_home/workspace/cicd-project/jmeter_folder/html/wikipedia
                        '''

                        storeJMeterResultsInDatabase("/var/jenkins_home/workspace/cicd-project/jmeter_folder/csv/wikipedia.csv")
                    } catch (Exception e) {
                        echo "Error during JMeter tests: ${e.getMessage()}"
                        currentBuild.result = 'FAILURE'
                        error("Stopping pipeline due to JMeter test failure")
                    }
                }
            }
        }

        stage('Convert and Transfer Script') {
            steps {
                script {
                    try {
                        withCredentials([sshUserPrivateKey(credentialsId: 'ssh-credential-id', keyFileVariable: 'SSH_KEY_FILE'),
                                         usernamePassword(credentialsId: 'docker-repo-credentials', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                            def bashScript = "/var/jenkins_home/workspace/${env.JOB_NAME}/deployment_testserver.sh"
                            def apiFolder = "/var/jenkins_home/workspace/${env.JOB_NAME}/newman"

                            sh "dos2unix ${bashScript}"

                            sh """
                                scp -i ${SSH_KEY_FILE} -o StrictHostKeyChecking=no ${bashScript} development@10.18.22.18:/home/development/
                                rsync -avz -e "ssh -i ${SSH_KEY_FILE} -o StrictHostKeyChecking=no" ${apiFolder} development@10.18.22.18:/home/development/
                            """

                            sh "ssh -i ${SSH_KEY_FILE} development@10.18.22.18 'chmod +x /home/development/deployment_testserver.sh'"

                            sh "ssh -i ${SSH_KEY_FILE} development@10.18.22.18 'DOCKER_USER=${DOCKER_USER} DOCKER_PASS=${DOCKER_PASS} bash /home/development/deployment_testserver.sh'"
                        }
                    } catch (Exception e) {
                        echo "Error during script transfer or execution: ${e.getMessage()}"
                        currentBuild.result = 'FAILURE'
                        error("Stopping pipeline due to failure in script transfer or execution.")
                    }
                }
            }
        }
    }
}

def storeReportInDatabase(reportName, reportContent) {
    def dbUrl = "jdbc:postgresql://api-test-sonar_db-1:5432/api_test_reports"
    def dbUser = "sonar"
    def dbPassword = "sonar"
    def driver = 'org.postgresql.Driver'

    Class.forName(driver)

    def sql = groovy.sql.Sql.newInstance(dbUrl, dbUser, dbPassword, driver)

    sql.execute("INSERT INTO reports (name, content) VALUES (?, ?)", [reportName, reportContent])
}

def storeJMeterResultsInDatabase(csvFilePath) {
    def dbUrl = "jdbc:postgresql://api-test-sonar_db-1:5432/api_test_reports"
    def dbUser = "sonar"
    def dbPassword = "sonar"
    def driver = 'org.postgresql.Driver'

    try {
        Class.forName(driver)
        echo "Driver loaded successfully"
    } catch (Exception e) {
        echo "Error loading driver: ${e.getMessage()}"
        return
    }

    def sql = null
    try {
        sql = groovy.sql.Sql.newInstance(dbUrl, dbUser, dbPassword, driver)
        echo "Connected to database"
    } catch (Exception e) {
        echo "Error connecting to database: ${e.getMessage()}"
        return
    }

    def csvContent = readFile(file: csvFilePath).split('\n')
    echo "CSV content: ${csvContent}"
    csvContent.each { line ->
        def columns = line.split(',')
        echo "Processing line: ${line}"
        if (columns.size() > 1) {
            def timeStamp = columns[0]
            def elapsed = columns[1]
            def label = columns[2]
            def responseCode = columns[3]
            def threadName = columns[4]
            def success = columns[7]

            try {
                sql.execute("INSERT INTO jmeter_results (timestamp, response_time, label, response_code, thread_name, success) VALUES (?, ?, ?, ?, ?, ?)",
                    [timeStamp, elapsed, label, responseCode, threadName, success.toBoolean()])
                echo "Inserted row into database"
            } catch (Exception e) {
                echo "Error inserting row: ${e.getMessage()}"
            }
        }
    }
}
