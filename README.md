# aws-pdm-dataset-generation
Repo for PDM dataset generation

## Retries on cluster failure

When the PDM cluster fails or succeeds it creates a cloudwatch event. A cluster can fail for a multitude of reasons, therefore 
an automated retry of a failed cluster is warranted.   

PDM logs its run information into a DynamoDB table with the following structure:  

| Correlation_Id | DataProduct |    Date    | Run_Id | Status | CurrentStep | TimeToExist | Cluster_Id |   S3_Prefix_Snapshots   |   S3_Prefix_Analytical_DataSet   |   Snapshot_Type   |
|----------------|-------------|------------|--------|--------|-------------|-------------|------------|-------------------------|-------------------------------|-------------------|
|      123       |     PDM     | 2021-02-11 |    1   | FAILED |    Model    |             | j-1SM0GDS5 | path_to_snapshot_data/  | path_to_analytical_data/       |        full         | 
    
The cluster will log information resembling the above DynamoDB table. If it fails, it will kick off a cloudwatch event that has a target lambda - [dataworks-emr-relauncher](https://github.com/dwp/dataworks-emr-relauncher)   
The retry logic is contained within that lambda as well as more detailed documentation. If the failed cluster is restarted
it will skip to the failed step and resume from there. 
