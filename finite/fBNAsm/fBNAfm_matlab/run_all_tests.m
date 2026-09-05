% run_all_tests.m - Master script to run all SRBM tests
%
% This script runs all validation and reproduction tests for the
% Dai & Harrison (1991) SRBM algorithm implementation.

clear; clc;
close all;

fprintf('*****************************************************************\n');
fprintf('*  SRBM IN RECTANGLE - TEST SUITE                               *\n');
fprintf('*  Implementation of Dai & Harrison (1991) Algorithm            *\n');
fprintf('*****************************************************************\n\n');

%% Run basic validation tests
fprintf('Running basic validation tests...\n');
fprintf('-----------------------------------------------------------------\n');
test_basic_validation;
fprintf('\n');

%% Run Table 2 reproduction
fprintf('\n\nRunning Table 2 reproduction test...\n');
fprintf('-----------------------------------------------------------------\n');
test_table2;
fprintf('\n');

%% Run Table 1 (tandem queue) reproduction
fprintf('\n\nRunning Table 1 (tandem queue) reproduction test...\n');
fprintf('-----------------------------------------------------------------\n');
test_table1_tandem_queue;
fprintf('\n');

fprintf('*****************************************************************\n');
fprintf('*  ALL TESTS COMPLETE                                           *\n');
fprintf('*****************************************************************\n');
