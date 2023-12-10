import React from 'react';
import java from '../assets/java.svg';
import aws from '../assets/aws.svg';
import css from '../assets/css.svg';
import flask from '../assets/flask.svg';
import git from '../assets/git.svg';
import python from '../assets/python.svg';
import js from '../assets/js.svg';
import mysql from '../assets/mysql.svg';
import nodejs from '../assets/nodejs.svg';
import react from '../assets/react.svg';
import android from '../assets/android.png';
import favicon from '../assets/favicon.ico';
import { colors } from '@mui/material';

export const images = {
	java,
	aws,
	css,
	flask,
	git,
	python,
	js,
	mysql,
	nodejs,
	react,
	android,
	favicon,
};

type InitialIconProps = {
	initials: string;
};

export const InitialIcon: React.FC<InitialIconProps> = ({ initials }) => {
	return (
		<div
			style={{
				backgroundColor: colors.blueGrey[500],
				alignItems: 'center',
				justifyContent: 'justify',
				borderRadius: 30,
				width: 50,
				height: 50,
			}}
		>
			<h2 style={{ color: 'white', fontSize: 25 }}>{initials}</h2>
		</div>
	);
};
