# application-boilerplate

A boilerplate Terraform template that provisions a frontend app through static web hosting and a backend service.

## Overview

This repository contains Terraform templates that help you quickly deploy a frontend static website and a backend service using AWS infrastructure. The frontend app is served via AWS S3, CloudFront for content delivery, and Route 53 for DNS management. 

## Frontend Setup

The static frontend app is described in detail in the following article:  
[Deploy a Static Website with AWS S3, CloudFront, and Terraform](https://denisgulev.com/static-website-with-aws-s3-cloudfront-and-terraform/).

In this article, you'll find a step-by-step guide on how to set up an S3-backed static website using Terraform, including CloudFront distribution, DNS configuration with Route 53, and more.

## Backend Setup

// TODO

## How to Use

1. Clone this repository:
   ```bash
   git clone https://github.com/your-username/application-boilerplate.git
   cd application-boilerplate
   ```
2.	Customize the variables in the frontend and backend directories to suit your needs.
3.	Follow the instructions in the linked article to deploy the frontend static website.